import Foundation

/// The optional jev ADVISORY bridge.
///
/// jev is a user-configured HTTP decision service. Pop defines the contract:
///
///   POST <endpoint>          Authorization: Bearer <token>   x-api-key: <token>
///   {"model": "jev-latest", "state": string,
///    "questions": {"q": {"type": "choice", "instructions": string,
///                        "criteria": {label: description}}}}
///   -> 200 {"model": ..., "answers": {"q": {"type": "choice", "choice": label,
///            "probabilities": {label: 0..1}}}, "usage": {...}}
///
/// FAIL-OPEN BY CONSTRUCTION: disabled or unreachable, `advisory(...)` returns
/// nil and Pop proceeds on its rule-based defaults — jev shapes a label, it
/// NEVER blocks, delays a verdict beyond its own 3 s bound, or throws into a
/// caller. Its presence is advisory; its absence is invisible to the pipeline.
///
/// The bearer token lives ONLY in the Keychain (account "jev"); no JEV_ log line
/// ever carries it.
///
/// NONISOLATED on purpose: the Keychain read blocks up to 10 s and the HTTP call
/// up to 3 s. Pinned to the MainActor those waits would freeze the UI mid-approval
/// (worst case ~13 s), making the "3 s bound" a lie. As plain `static func`s they
/// run on the caller's executor, off-main, and the URLSession request timeout is
/// then the ONLY bound that matters. The one mutable static — the memoized token
/// — is lock-guarded; `Advisory` is a value type.
enum JevBridge {
    /// One parsed advisory. `probabilities` is the raw label -> confidence map;
    /// the THRESHOLD is applied by the caller, not here.
    struct Advisory: Sendable, Equatable {
        let choice: String
        let probabilities: [String: Double]
    }

    /// Hard bound on the advisory call. Short on purpose: jev must never be the
    /// reason an approval card is late.
    static let timeout: TimeInterval = 3

    /// Keychain account for the jev bearer token. Distinct from the chat key's
    /// provider-named account.
    static let tokenAccount = "jev"

    /// The one question id Pop sends. The SystemOne response is KEYED by question
    /// id, so the parser reads exactly this key (with a flattened top-level
    /// fallback for a single-question service that drops the wrapper).
    static let questionID = "q"

    /// The BARE wire model id REQUIRED by the jev request (jev.md §2). Pop's
    /// `jevModel` config is fully-qualified for transport selection — e.g.
    /// `typesafe/jev-latest` — but the WIRE id must be bare: a provider prefix
    /// selects the transport and is stripped before the request. Empty config
    /// falls back to the default spec's bare id, `jev-latest`. A missing/empty
    /// `model` is exactly the live `400 api_usage_error`, so this never returns
    /// empty. Pure, so a probe can truth-table it without a server.
    static func wireModel(from configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "jev-latest" }
        let prefix = "typesafe/"
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
    }

    /// Memoized jev bearer token, guarded by `tokenLock`.
    ///
    /// WHY: `KeychainStore.apiKey` can block up to its 10 s deadline on a slow
    /// or prompting Keychain. Re-reading it on EVERY advisory would re-pay that
    /// cost each turn, and that un-memoized read is exactly the measured PROBE
    /// flake (a bounded advisory occasionally blew past its asserted bound).
    /// ONLY a successful non-empty read is cached; a nil/timeout result is left
    /// uncached so a transient Keychain failure retries on the next advisory.
    private static let tokenLock = NSLock()
    private static var cachedToken: String?

    /// Per-run degradation-notice seam. Set by ChatController at init to surface
    /// a CONFIGURED-but-dead advisory service ONCE; nil in probes, so their
    /// advisory calls stay silent.
    ///
    /// WHY: a configured-but-dead advisory service must announce itself once.
    /// Per-call notices would spam every approval card (and every run-label
    /// boundary) while the service stays down, and today's silence is exactly
    /// what let a fabricated answer go unnoticed for two rounds.
    static var onFirstFailure: ((String) -> Void)?

    /// Guards the one-shot latch AND the callback reference — `advisory` may run
    /// off-main and concurrently. `announcedFailure` is the latch: set when a
    /// failure is announced and CLEARED on any success, because the notice
    /// describes a STATE (configured-but-unreachable), not an event.
    private static let noticeLock = NSLock()
    private static var announcedFailure = false

    /// Fires `onFirstFailure` at most once per run for a run of failures. Called
    /// ONLY from the enabled path, so a disabled/absent jev stays silent.
    private static func noteFailure(_ reason: String) {
        noticeLock.lock()
        let shouldAnnounce = !announcedFailure
        announcedFailure = true
        let callback = onFirstFailure
        noticeLock.unlock()
        guard shouldAnnounce, let callback else { return }
        callback(reason)
    }

    /// Re-arms the one-shot latch after a SUCCESSFUL advisory, so a service that
    /// recovers and later dies again notifies afresh on the next failure. The
    /// notice describes a state, not an event: recovery clears it.
    static func noteSuccess() {
        noticeLock.lock()
        announcedFailure = false
        noticeLock.unlock()
    }

    /// Records ONE enabled-path failure: logs it and folds the sanitized reason
    /// into the once-per-run notice. Every failure below funnels through here,
    /// so the disabled fast-path `guard` can never notify.
    private static func fail(_ reason: String) -> Advisory? {
        log("JEV_UNAVAILABLE reason=\(reason)")
        noteFailure(sanitize(reason))
        return nil
    }

    /// The jev token, or nil. Reads the Keychain at most once per process once a
    /// read succeeds; failures are never memoized.
    private static func token() -> String? {
        tokenLock.lock()
        let cached = cachedToken
        tokenLock.unlock()
        if let cached { return cached }
        guard let read = KeychainStore.apiKey(for: tokenAccount), !read.isEmpty else {
            return nil
        }
        tokenLock.lock()
        cachedToken = read
        tokenLock.unlock()
        return read
    }

    /// Fetches an advisory, or nil. Fast nil when jev is off/unconfigured (NO
    /// network call). ANY failure — HTTP, parse, unreachable, timeout — logs
    /// `JEV_UNAVAILABLE` and returns nil; nothing here throws.
    static func advisory(
        goal: String,
        question: String,
        options: [String: String]
    ) async -> Advisory? {
        // The SystemOne dialect, verbatim per jev.md §2. Pop's old flat
        // {goal,question,options} body — and the interim {goal, questions:[…]}
        // body — are rejected by the live service with HTTP 400. The verified
        // shape is `{model, state, questions:{<id>:{type,instructions,criteria}}}`:
        //   * `questions` is a RECORD keyed by question id, NEVER an array;
        //   * `model` is REQUIRED and its BARE id (`jev-latest`) — a `typesafe/`
        //     provider prefix is stripped before sending. Omitting `model` is
        //     exactly the live `400 api_usage_error` this replaces;
        //   * the situation text rides `state` (Pop's `goal` maps here).
        // goal/question/options map onto state/instructions/criteria.
        let systemOneQuestion: [String: Any] = [
            "type": "choice",
            "instructions": question,
            "criteria": options
        ]
        guard let data = await fetch(
            goal: goal,
            questions: [Self.questionID: systemOneQuestion]
        ) else {
            return nil
        }
        guard let advisory = parseAdvisory(data) else {
            return fail("unparseable-response")
        }
        let strength = advisory.probabilities[advisory.choice] ?? 0
        log("JEV_ADVISORY choice=\(sanitize(advisory.choice)) p=\(String(format: "%.2f", strength))")
        // A REAL answer re-arms the one-shot notice: the service is back.
        noteSuccess()
        return advisory
    }

    /// The shared SystemOne POST. Builds `{model, state, questions}`, sends it
    /// with the bearer token, and returns the response BODY on 2xx. A disabled/
    /// unconfigured jev returns nil SILENTLY (no network call); ANY other failure
    /// — missing token, HTTP status, transport — logs `JEV_UNAVAILABLE` and
    /// returns nil. Nothing here throws. Both `advisory` (choice) and
    /// `premiseCheck` (noul) parse the same envelope from this one transport.
    private static func fetch(goal: String, questions: [String: Any]) async -> Data? {
        guard let config = try? PopConfig.load(),
              config.jevEnabled,
              !config.jevEndpoint.isEmpty,
              let url = URL(string: config.jevEndpoint) else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A configured jev REQUIRES its bearer token: sending an unauthenticated
        // request would leak the goal/question and get a confusing 401 instead of
        // a clean "unavailable". Fail fast, before any network call. The read is
        // memoized (`token()`), so a slow Keychain is paid at most once.
        guard let token = token() else {
            return failData("missing-token")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The service's auth scheme is unconfirmed (Bearer vs x-api-key), so send
        // BOTH with the SAME token. The duplication is harmless and maximally
        // compatible; the token still never reaches a log or the request body.
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        let body: [String: Any] = [
            "model": Self.wireModel(from: config.jevModel),
            "state": goal,
            "questions": questions
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // A non-2xx is how a dialect mismatch announces itself. Print a
                // TRUNCATED, sanitized copy of the body (never the request, never
                // the token) so the next contract drift diagnoses itself instead
                // of needing a hand curl.
                let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                log("JEV_HTTP_STATUS=\(http.statusCode) body=\(sanitize(snippet, limit: 200))")
                return failData("http-status-\(http.statusCode)")
            }
            return data
        } catch {
            // Unreachable / timed out / offline: advisory unavailable, Pop carries
            // on with defaults.
            return failData(error.localizedDescription)
        }
    }

    /// The `Data?` twin of `fail(_:)`: logs the failure, folds it into the
    /// once-per-run notice, and returns nil.
    private static func failData(_ reason: String) -> Data? {
        log("JEV_UNAVAILABLE reason=\(reason)")
        noteFailure(sanitize(reason))
        return nil
    }

    /// Pure parse of the SystemOne response body — URLSession-free so a probe can
    /// test it without a server.
    ///
    /// The response echo (jev.md §2) is `{"model": "<bare id>", "answers":
    /// {"<id>": {"type":"choice","choice":…,"probabilities":{…}}}, "usage":{…}}`.
    /// Pop always asks one question with id `questionID`, so the parser reads
    /// exactly `answers["q"]`.
    ///
    /// FAIL-OPEN ENVELOPE RULE (jev.md §2): the transport marker IS the envelope
    /// `model` echo. An envelope whose `model` is missing/empty is NOT a decision
    /// response — return nil rather than folding whatever `answers` happens to
    /// hold. Nil on: not JSON, missing/empty envelope `model`, missing `answers`/
    /// id, missing `choice`, or a `probabilities` map whose values are not
    /// numbers. An extra answer field (say `confidence`) is simply ignored.
    /// DEFENSIVE fallback (off the happy path, harmless): a service that flattens
    /// its reply (drops the `answers` wrapper) is still accepted when the object
    /// itself carries `choice` + `probabilities`.
    static func parseAdvisory(_ data: Data) -> Advisory? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Envelope-model check FIRST: an empty/missing `model` fails open (nil).
        guard let model = object["model"] as? String, !model.isEmpty else {
            return nil
        }
        let answer = (object["answers"] as? [String: Any])?[questionID] as? [String: Any]
            ?? (object[questionID] as? [String: Any])
            ?? object
        guard let choice = answer["choice"] as? String,
              let rawProbabilities = answer["probabilities"] as? [String: Any] else {
            return nil
        }
        var probabilities: [String: Double] = [:]
        for (label, value) in rawProbabilities {
            guard let number = value as? NSNumber else { return nil }
            probabilities[label] = number.doubleValue
        }
        return Advisory(choice: choice, probabilities: probabilities)
    }

    /// The one question id for the PREMISE noul. Distinct from `questionID` so a
    /// reply can never be read as the wrong question type.
    static let premiseQuestionID = "p"

    /// The premise floor, pure and URLSession-free so a probe can truth-table it.
    /// A noul IS the signal (0.5 = unsure), so it is compared to a floor, not
    /// truthinessed: a JSON `true` never stands in for a number.
    static func premiseHolds(noul: Double) -> Bool { noul >= 0.7 }

    /// One `noul` question: is the request's PREMISE true and actionable? A noul
    /// answer is a NUMBER (0..1), never boolean and never a choice/probability
    /// map. FAIL-OPEN: `nil` on disabled/unconfigured/unreachable/unparseable, so
    /// a premise Pop cannot measure is assumed true and the route stands. Bounded
    /// by the same `timeout` as every other advisory, so it can never delay a
    /// turn beyond 3 s.
    static func premiseCheck(goal: String) async -> Bool? {
        let question: [String: Any] = [
            "type": "noul",
            "instructions": "Is the premise of this request true and actionable?"
        ]
        guard let data = await fetch(
            goal: goal,
            questions: [Self.premiseQuestionID: question]
        ) else {
            return nil
        }
        guard let noul = parseNoul(data) else { return nil }
        let holds = premiseHolds(noul: noul)
        let value = String(format: "%.2f", noul)
        if holds {
            log("JEV_PREMISE noul=\(value)")
        } else {
            log("JEV_PREMISE noul=\(value) -> route-skipped")
        }
        return holds
    }

    /// Pure parse of the noul answer row — URLSession-free so a probe can
    /// truth-table it. The row is `{"type":"noul","noul":0.83}` under the keyed
    /// `answers` map (with the same flattened fallback `parseAdvisory` uses).
    ///
    /// The envelope `model` echo rule is shared. A JSON boolean bridges to
    /// `NSNumber`, so it is rejected EXPLICITLY — the contract is "noul is a
    /// number, never boolean" — as are non-finite and out-of-range values: a
    /// malformed row fails open to nil rather than becoming truthy.
    static func parseNoul(_ data: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let model = object["model"] as? String, !model.isEmpty else {
            return nil
        }
        let answer = (object["answers"] as? [String: Any])?[premiseQuestionID] as? [String: Any]
            ?? (object[premiseQuestionID] as? [String: Any])
            ?? object
        guard let number = answer["noul"] as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let value = number.doubleValue
        guard value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    /// The below-threshold decision, pure and URLSession-free so a probe can
    /// truth-table it. The floor is the USER's signal-to-noise control: an
    /// advisory at or above it is shown, one below it is dropped entirely.
    static func belowThreshold(strength: Double, floor: Double) -> Bool {
        strength < floor
    }

    /// Log-injection guard for EXTERNAL strings (the service's `choice` is
    /// untrusted): collapse newlines/tabs to spaces and cap at 40 chars so one
    /// hostile label cannot forge log lines or flood the transcript. Kept as a
    /// one-argument function so it can still be passed as `(String) -> String`
    /// (e.g. `map(JevBridge.sanitize)`).
    static func sanitize(_ value: String) -> String {
        sanitize(value, limit: 40)
    }

    /// The same collapse with an explicit cap — a refusal BODY uses a larger
    /// `limit` than a label.
    static func sanitize(_ value: String, limit: Int) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(flattened.prefix(limit))
    }

    private static func log(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

/// JEV RUN-STATE LABELING (SPEC §4.4 use (c)).
///
/// THE INVARIANT: jev labels long runs but never steers them. This type holds
/// only the PURE decisions — whether a run is long enough to label, and whether
/// an advisory deserves a transcript notice. The notice is the only output; the
/// agent loop owns every decision, so a missing or hostile advisory changes
/// nothing about control flow (the fail-open contract).
enum JevRunLabel {
    /// Label after this many MUTATING tool rounds in one turn.
    ///
    /// WHY 6: a run of six mutating acts is long enough that a stall or drift is
    /// worth a nudge, and it mirrors `AgentLoop.maxRounds` — the loop's own hard
    /// ceiling — so the label can never be emitted after the turn's last round
    /// anyway. It is a fixed constant, not config: a knob here would only let the
    /// user turn a read-only labeler into noise.
    static let everyRounds = 6

    /// The advisory contract for a run-state classification.
    static let question = "run_state"
    static let options: [String: String] = [
        "thriving": "progressing normally",
        "stall": "repeating actions without progress",
        "drift": "wandering from the stated goal"
    ]

    /// PURE fire condition for the loop: jev must be on AND the turn must have
    /// reached a multiple of `everyRounds` MUTATING rounds. Read-only rounds
    /// cannot accumulate, so a turn of only reads never labels.
    static func shouldLabel(enabled: Bool, mutatingRounds: Int) -> Bool {
        enabled && mutatingRounds > 0 && mutatingRounds % everyRounds == 0
    }

    /// PURE choice-to-notice decision. Returns whether the label earns a
    /// transcript notice, and the exact `JEV_RUN_LABEL` token. Only `stall` and
    /// `drift` at or above the user's floor are noticed; anything else is a
    /// silent log line. `nil` advisories are handled by the caller (unavailable).
    static func shouldNotice(
        choice: String,
        strength: Double,
        floor: Double
    ) -> (notice: Bool, label: String) {
        let named = (choice == "stall" || choice == "drift")
        guard named else { return (false, "choice=\(choice)") }
        guard strength >= floor else { return (false, "skipped=below-threshold") }
        return (true, "choice=\(choice) p=\(String(format: "%.2f", strength))")
    }
}

/// JEV SKILL ROUTING (SPEC §4.4 use (a)).
///
/// THE INVARIANT: jev shapes the turn with at most one advisory hint and never
/// steers it. This type holds only the PURE decisions — which capability classes
/// exist, whether routing is on, and whether an advisory earns a hint line. The
/// hint rides the model's context at most once; a missing, below-floor, or
/// ignored advisory leaves the loop byte-identical (the fail-open contract).
enum JevRoute {
    /// The capability classes that EXIST in Pop today — and NOTHING else.
    ///
    /// WHY: routing is over REAL capability classes only. A class Pop cannot
    /// execute (say "image-gen") must never be OFFERED, or jev could return a
    /// class no tool provides and the hint would name a capability the model
    /// cannot reach — a lie. Every key here maps to tools actually registered.
    static let options: [String: String] = [
        "computer-use": "drive apps and UI with ui_*/app_manage tools",
        "browser": "drive pages with browser_* tools",
        "files": "read/write/search files and run shell commands",
        "web": "web_lookup research",
        "chat": "plain conversation, no tools"
    ]

    /// The capability classes whose work NEEDS mutating tools the on-device brain
    /// lacks: it refuses every mutating tool with
    /// `FM_TOOL_SKIP ... not-on-device-eligible`, so a route into one of these
    /// cannot be served on-device and is promoted to the remote brain. ONE
    /// definition, shared by the promotion gate AND the consistency assertion in
    /// `--test-jev-route` (every member must exist in `options`).
    static let handsOnClasses: Set<String> = ["computer-use", "browser"]

    /// PURE fire condition for the loop: routing happens only when jev is on.
    static func shouldRoute(enabled: Bool) -> Bool { enabled }

    /// PURE choice-to-hint decision. `nil` unless the choice names a REAL
    /// capability class AND its strength clears the user's floor. The returned
    /// string is the sanitized LOG token; the caller reads `advisory.choice`
    /// (raw) to build the model-facing context line.
    static func hint(from advisory: JevBridge.Advisory, floor: Double) -> String? {
        // The class must EXIST before anything else — an unknown label is not a
        // low-confidence route, it is no route at all.
        guard options[advisory.choice] != nil else { return nil }
        let strength = advisory.probabilities[advisory.choice] ?? 0
        guard strength >= floor else { return nil }
        return "jev routing hint: \(JevBridge.sanitize(advisory.choice))"
            + " (p=\(String(format: "%.2f", strength)))"
    }
}
