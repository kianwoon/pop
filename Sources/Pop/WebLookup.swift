import AppKit
import Foundation
import WebKit

/// The small structured result of one `web_lookup`.
///
/// The caller gets an extraction, never a DOM dump: `answerExcerpt` is capped
/// hard and `provenance` says honestly how strong the claim is. The ASK-RULE is
/// PRECISION, not recall: the ask is reachable ONLY through caller-declared
/// slots (`declaredSlots` / `missingSlots`). `inferredNotInQuery` is retained as
/// clearly-labelled LOW-CONFIDENCE metadata for the action log only — it can
/// never produce user-facing text.
struct WebLookupResult: Sendable {
    var query: String
    var answerExcerpt: String
    /// The raw characters immediately before/after `answerExcerpt` in the
    /// whitespace-collapsed page text (empty string at the page edges). The
    /// extraction script reports them as EVIDENCE; the excerpt-quality probe
    /// re-derives the word/sentence-boundary verdict from them in Swift.
    var answerPrevChar: String
    var answerNextChar: String
    /// Whether the extraction actually located `answerExcerpt` in the page text
    /// and read its real neighbours. `false` on a failed locate, so the
    /// excerpt-quality gate can FAIL instead of silently skipping.
    var answerLocated: Bool
    /// Whether the content-term relation test was actually applied to the
    /// chosen region (false when the query had no content terms at all), and
    /// whether it passed. Together they prove the test is live rather than
    /// silently short-circuited.
    var relationApplied: Bool
    var relationPassed: Bool
    var sourceHost: String
    var sourceTitle: String
    var provenance: String
    /// LOW-CONFIDENCE metadata, logs only. Page tokens that looked parameter-like
    /// but were never declared by the caller. Deliberately incapable of
    /// producing an ask: `modelText`/`askText` do not read it.
    var inferredNotInQuery: [String]
    /// Required parameter NAMES declared by the caller (e.g. `["origin"]`). A
    /// self-contained question such as weather declares nothing. Pop only ever
    /// checks presence/absence of these; it has no built-in value lists.
    var declaredSlots: [String]
    /// Declared slots the query did not supply. Non-empty means: ASK. This is
    /// the ONLY input that can make Pop ask.
    var missingSlots: [String]
    /// Page values offered as SUGGESTIONS for the missing slots, never as fact.
    /// Only ever surfaced when a declared slot is missing.
    var slotCandidates: [String]
    /// Non-empty when a consent / captcha / JS wall was detected, so the caller
    /// degrades instead of inventing an answer.
    var wall: String
    /// A one-line marker for Pop's own panel / action log.
    var marker: String
    var domChars: Int
    var payloadChars: Int
    var usedURL: String
    /// Which declared source supplied the location: `core` (macOS Core
    /// Location), `config` (the configured default city), or `serp` (none — the
    /// page's own inference is the only thing available).
    var locSource: String
    /// The resolved city NAME only. Empty when `locSource == serp`. Coordinates
    /// are never carried here.
    var locCity: String
    /// How the location reached Google: `params` (uule + hl/gl), `text`
    /// (appended to the query), or `both`. Empty when there was no location.
    var locMethod: String
    var locEmbedded: Bool

    /// The text handed back to the caller. Small on purpose: every byte rides
    /// into the next request.
    ///
    /// THE ASK-RULE, enforced HERE at the model boundary: the ask is reachable
    /// ONLY through a caller-DECLARED slot the query never supplied
    /// (`missingSlots`). The generic page-entity detector cannot reach this
    /// branch at all, so a scraped acronym such as `HNMS` or a time word such as
    /// `Afternoon` can never turn into a question. Fully generic: only the
    /// caller's own declared names are named here.
    var modelText: String {
        if !missingSlots.isEmpty {
            let slots = missingSlots.joined(separator: ", ")
            return """
            web_lookup: the question did not state required parameter(s): \(slots).
            DO NOT present the source's values as fact and do NOT answer yet. ASK the user to supply the missing parameter(s), naming \(slots). Look it up again only after the user answers.
            """
        }
        var lines: [String] = [
            marker,
            "source: \(sourceHost) \u{2014} \"\(sourceTitle)\"",
            "answer: \(answerExcerpt.isEmpty ? "(no extractable answer)" : answerExcerpt)",
            "provenance: \(provenance)"
        ]
        if !wall.isEmpty {
            lines.append("wall: \(wall)")
        }
        return lines.joined(separator: "\n")
    }

    /// The user-facing ASK, composed by POP — never by the model.
    ///
    /// The model paraphrased the tool's list and invented an extra city into the
    /// very sentence meant to avoid invented values (measured: "Beijing" in an
    /// ask whose tool list was `Senai International Airport | Incheon
    /// International | Taipei Sung Shan | Singapore Changi`). So the ask is a
    /// pure function of the caller's OWN declared slot names: each is wrapped in
    /// backticks verbatim and nothing else is named. Page candidates, when
    /// present, are also backticked but EXPLICITLY labelled a suggestion, never
    /// fact. No origin, city, airport, currency or time-of-day logic lives here.
    /// The ask-honesty gate extracts the backticked spans and requires each to be
    /// a member of `declaredSlots` ∪ `slotCandidates`.
    /// Returns `nil` for an EMPTY (or all-whitespace) slot list. Callers guard
    /// today, but nothing stopped a future caller from rendering
    /// `"I need the  to answer that \u{2014} ..."` — a double space and a missing
    /// value. The guard lives HERE so the template can never render without a
    /// named slot, and `nil` is the caller's signal to set `ASK_FIRED=false`.
    static func askText(for slots: [String], candidates: [String] = []) -> String? {
        let namedSlots = slots
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !namedSlots.isEmpty else { return nil }
        let named = namedSlots.map { "`\($0)`" }.joined(separator: ", ")
        var text = "I need the \(named) to answer that \u{2014} it was not in your question. "
        if !candidates.isEmpty {
            let suggested = candidates.map { "`\($0)`" }.joined(separator: ", ")
            text += "The page showed \(suggested), but that is only a suggestion, not confirmed. "
        }
        return text + "Which one is correct, or can you provide the missing value?"
    }

    /// A declared slot is PRESENT when the query itself contains the slot's name
    /// (word-boundary, case-insensitive). This is the whole presence/absence
    /// test: no domain knowledge, no value lists — the caller's declared name is
    /// the only thing Pop checks against the query.
    static func slotIsPresent(_ slot: String, in query: String) -> Bool {
        let norm: (String) -> String = { raw in
            let allowed = CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "\u{00c0}-\u{024f}"))
            let words = raw.lowercased()
                .components(separatedBy: allowed.inverted)
                .filter { !$0.isEmpty }
            return " " + words.joined(separator: " ") + " "
        }
        let needle = norm(slot)
        guard needle.trimmingCharacters(in: .whitespaces).count >= 2 else { return true }
        return norm(query).contains(needle)
    }
}

/// A read-only, DOMAIN-AGNOSTIC web lookup over Pop's own offscreen `WKWebView`.
///
/// It is deliberately not a flight tool or a weather tool: there is not one
/// site-specific selector below. It navigates the embedded view offscreen,
/// waits for script to settle, then extracts generically — the densest text
/// near the query's own terms — and reports what the page INFERRED that the
/// query did not state. The user's real browser is never opened or touched.
@MainActor
enum WebLookup {
    /// THE WEB-QUESTION RULE — one generic sentence, no per-site logic: a web
    /// lookup NEVER asks the user for missing details before searching. It
    /// searches and answers from the page. The only question that may be
    /// relayed is one the PAGE ITSELF asks, reported verbatim and attributed to
    /// the page rather than paraphrased into invented parameters.
    nonisolated static let pageQuestionRule = """
        WEB-QUESTION: `web_lookup` ALWAYS searches and answers from the page — \
        never ask the user for details first. If the page itself asks the user \
        for more information, relay that question verbatim and attribute it to \
        the page (for example "Google is asking: ..."); never invent the \
        parameters yourself.
        """

    /// The excerpt ceiling. The gate is ≤700; this keeps headroom.
    static let answerCap = 600
    /// A SERP paints its answer well after `didFinish`; this is the settle.
    static let settleDelay: TimeInterval = 5
    /// Pause after the session-warm navigation at the site root, so the
    /// first-party cookies the root page sets are committed before the query
    /// navigation goes out. The previous 2s was measured to be too short for the
    /// root page to finish its own script-driven cookie writes, so it is the
    /// SERP settle rather than a new shorter guess.
    static let sessionWarmDelay: TimeInterval = 5
    /// Pause after the one consent click, so the interstitial's own navigation
    /// (and the cookie it sets) completes before the cookie jar is read.
    static let consentSettleDelay: TimeInterval = 3
    static let extractionTimeout: TimeInterval = 8
    /// Outer guard for navigate + settle + eval.
    static let outerTimeout: TimeInterval = 45

    /// The query string a caller turns into a URL. `hl=en` keeps the rendered
    /// text in one language regardless of the machine's locale.
    ///
    /// When a location is supplied it is embedded two ways: Google's own
    /// location parameters (`uule` + the machine's `gl` country hint) and, as a
    /// fallback that always works, the city appended to the query text. The
    /// caller decides the mix (`params` / `text` / `both`); a probe can pin one
    /// with `POP_LOC_METHOD` to measure which actually localises the page.
    static func searchURL(
        for query: String,
        location: ResolvedLocation? = nil
    ) -> (url: String, method: String) {
        var text = query
        var items: [(String, String)] = []
        var used: [String] = []
        if let location {
            let wantParams = locMethodPreference != "text"
            let wantText = locMethodPreference != "params"
            if wantParams {
                items.append(("uule", uule(for: location.canonical)))
                if let region = Locale.current.region?.identifier, !region.isEmpty {
                    items.append(("gl", region.lowercased()))
                }
                used.append("params")
            }
            if wantText {
                text = query + " " + location.city
                used.append("text")
            }
        }
        items.insert(("q", text), at: 0)
        items.append(("hl", "en"))
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return (components.string ?? "https://www.google.com/search", used.joined(separator: "+"))
    }

    /// Probe seam for the embed method; unset means "both".
    private static var locMethodPreference: String {
        ProcessInfo.processInfo.environment["POP_LOC_METHOD"] ?? "both"
    }

    /// Google's v1 `uule`: a small protobuf (field1=2, field2=32, field4=the
    /// canonical name), base64-encoded and prefixed `w+`. Generic — the caller
    /// supplies the canonical string; there is no built-in place list here.
    static func uule(for canonical: String) -> String {
        var bytes: [UInt8] = [0x08, 0x02, 0x10, 0x20, 0x22]
        var length = Array(canonical.utf8).count
        while length >= 0x80 {
            bytes.append(UInt8((length & 0x7f) | 0x80))
            length >>= 7
        }
        bytes.append(UInt8(length))
        bytes.append(contentsOf: canonical.utf8)
        return "w+" + Data(bytes).base64EncodedString()
    }

    // MARK: - Session formation (the first visit)

    /// One warm per PROCESS: a real user's session is formed once, on the first
    /// visit, and every later query rides the same jar. Re-warming per query
    /// would be a navigation a returning user never makes. This flag is the ONLY
    /// thing that decides whether the warm runs.
    private static var sessionWarmDone = false

    /// How many times this process actually NAVIGATED the warm root. The
    /// single-warm evidence: after a second lookup in the same process this
    /// must still read 1, because a returning user's session is already formed
    /// and Pop does not make a navigation they never made.
    private static var warmRuns = 0

    /// Forms the session the way a FIRST VISIT forms it, then reports what the
    /// store actually accumulated.
    ///
    /// 1. the site ROOT with NO query in it — that is what a person's first
    ///    visit is, and it is where first-party cookies are set;
    /// 2. the ONE consent click a person would make, on the page's own control;
    /// 3. the cookie jar afterwards: NAMES and COUNT only. A cookie value is a
    ///    credential and never leaves the store.
    ///
    /// Generic: the root is derived from the host Pop is already navigating to.
    /// No site is named here, and there is no fallback engine — if the session
    /// cannot be formed, the lookup reports a wall rather than routing around it.
    @discardableResult
    static func warmSession(host: String) async -> [String] {
        let registrable = BrowserController.registrableHost(host)
        guard !registrable.isEmpty else { return [] }
        let browser = BrowserController.shared
        // DETERMINISTIC GATING: the per-process flag ALONE decides. The previous
        // gate also asked the cookie store whether the session was already
        // formed, and that read made a correctness-critical warm depend on live
        // state that could disagree with the web view's actual session — measured:
        // the store read reported cookies from an earlier run, the warm was
        // skipped (`WARM_RUNS=0` on all six lookups), and every query then hit
        // the wall cold. Whether to warm must not be a question about anything
        // outside this process. The cookie jar is still read, but only to REPORT
        // what the store holds (evidence), never to decide.
        if sessionWarmDone {
            print("WARM_SKIPPED=already-formed-this-process")
            print("WARM_RUNS=\(warmRuns)")
            let names = await browser.cookieNames(for: registrable)
            print("WARM_COOKIE_NAMES=\(names.joined(separator: " | "))")
            print("WARM_COOKIE_COUNT=\(names.count)")
            fflush(stdout)
            return names
        }
        sessionWarmDone = true
        warmRuns += 1
        let root = "https://\(registrable)/"
        print("WARM_ROOT=\(root)")
        fflush(stdout)
        _ = await browser.navigate(root, activatingPane: false)
        try? await Task.sleep(for: .seconds(sessionWarmDelay))
        let consent = await acceptConsentIfPresent()
        print("WARM_CONSENT_PAGE=\(consent.onConsentPage)")
        print("WARM_CONSENT_CLICKED=\(consent.clicked)")
        fflush(stdout)
        if !consent.clicked.isEmpty {
            try? await Task.sleep(for: .seconds(consentSettleDelay))
        }
        let names = await browser.cookieNames(for: registrable)
        print("WARM_COOKIE_NAMES=\(names.joined(separator: " | "))")
        print("WARM_COOKIE_COUNT=\(names.count)")
        print("WARM_RUNS=\(warmRuns)")
        fflush(stdout)
        return names
    }

    /// How many times this process has navigated the warm root. Exposed so a
    /// probe can print it as the single-warm evidence: two lookups in one
    /// process must report 1, never 2.
    static var warmRunCount: Int { warmRuns }

    /// What the consent pass found and did. `clicked` is the label of the
    /// control Pop clicked, verbatim from the page — the probe reports exactly
    /// which control the session was formed with.
    private struct ConsentOutcome {
        var onConsentPage = false
        var clicked = ""
    }

    /// The one click a person makes on a consent interstitial, made on the
    /// PAGE'S OWN control: Pop reads the labels a person reads, picks an ACCEPT
    /// one, and asks the page to click it (or submits its own form), so the
    /// site's own handler runs exactly as it would for a finger. Labels are
    /// matched as TEXT, never by a site selector, and a reject / decline /
    /// manage control is never clicked — if no accept control is present, nothing
    /// is clicked and the page is reported as it was found.
    private static func acceptConsentIfPresent() async -> ConsentOutcome {
        let json = await evaluate(
            BrowserController.shared.webView,
            consentScript,
            timeout: extractionTimeout
        )
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ConsentOutcome() }
        return ConsentOutcome(
            onConsentPage: (object["onConsentPage"] as? Bool) == true,
            clicked: (object["clicked"] as? String) ?? ""
        )
    }

    /// Generic consent handling: enumerate the page's own controls, read their
    /// visible labels, and click the first ACCEPT-flavoured one, most specific
    /// first. No site is named and no selector is site-specific.
    private static let consentScript = #"""
    (function () {
      var body = (document.body && (document.body.innerText || '')) || '';
      var lower = body.toLowerCase();
      var onConsentPage = /before you continue|consent|cookies/.test(lower);
      // ACCEPT labels only, most specific first. A person answering a consent
      // interstitial accepts; nothing here can reject or manage.
      var accepts = ['accept the use of cookies and continue',
        'accept the use of cookies', 'accept all cookies', 'accept all',
        'allow all', 'i agree', 'agree to all', 'got it', 'accept'];
      // Never clicked: the opposite decisions.
      var refuses = ['reject', 'decline', 'deny', 'manage', 'essential',
        'settings', 'privacy', 'more info'];
      var nodes = document.querySelectorAll(
        'button, input[type="submit"], input[type="button"], [role="button"]');
      var candidates = [];
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        var label = (n.innerText || n.value || n.getAttribute('aria-label') || '')
          .replace(/\s+/g, ' ').trim();
        if (!label || label.length > 60) { continue; }
        candidates.push({node: n, label: label, lower: label.toLowerCase()});
      }
      for (var a = 0; a < accepts.length; a++) {
        for (var c = 0; c < candidates.length; c++) {
          var cand = candidates[c];
          if (cand.lower.indexOf(accepts[a]) === -1) { continue; }
          var refused = false;
          for (var r = 0; r < refuses.length; r++) {
            if (cand.lower.indexOf(refuses[r]) !== -1) { refused = true; break; }
          }
          if (refused) { continue; }
          var form = cand.node.form
            || (cand.node.closest ? cand.node.closest('form') : null);
          if (form && typeof form.requestSubmit === 'function') {
            form.requestSubmit(cand.node.tagName === 'INPUT' ? null : cand.node);
          } else {
            cand.node.click();
          }
          return JSON.stringify({onConsentPage: onConsentPage,
            clicked: cand.label, tag: cand.node.tagName.toLowerCase()});
        }
      }
      return JSON.stringify({onConsentPage: onConsentPage, clicked: '', tag: ''});
    })();
    """#

    static func run(query: String) async -> WebLookupResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // NO PRE-SEARCH ASK. A web lookup ALWAYS performs the search and answers
        // from the page. The declared/missing slot machinery is retained in this
        // type for non-web callers, but a web lookup never populates it, so no
        // ask can fire before searching: both are empty by construction.
        let declared: [String] = []
        let missing: [String] = []
        // LOCATION: Core Location first, then the configured default city, else
        // the page's own inference. Never blocks the lookup; never invents one.
        let location = await LocationProvider.shared.resolve()
        let request = searchURL(for: trimmed, location: location)
        let url = request.url
        let method = request.method
        print("LOC_SOURCE=\(location?.source.rawValue ?? LocationSource.serp.rawValue)")
        print("LOC_CITY=\(location?.city ?? "")")
        print("LOC_METHOD=\(method)")
        print("LOC_EMBEDDED=\(location != nil && !method.isEmpty)")
        fflush(stdout)
        let browser = BrowserController.shared
        // Counted BEFORE the navigation: this is the process's only web-lookup
        // network entry point, so a turn that leaves it at zero made no call.
        ProviderTestSeams.shared.webLookupCount += 1
        // Started BEFORE the location resolve, so `LOOKUP_MS` is the whole cost
        // the turn paid for this lookup, warm included.
        let lookupStarted = Date()
        // OFFSCREEN: never opens Pop's visible browser pane, so a lookup cannot
        // occlude the answer it produced.
        // SESSION FORMATION, measured. A real end user's FIRST visit to a site
        // is the site's own ROOT page with no query in it — that is what forms
        // the session (first-party cookies are set there, and any consent
        // interstitial is answered there). Teleporting straight into a `/search`
        // URL on a cold jar is not a first visit, and the store stayed empty
        // (measured: `SESSION_COOKIE_NAMES=` blank, no NID/CONSENT). So the
        // lookup warms the session at the ORIGIN ROOT first, clicks the
        // interstitial the way the user would (the page's own control, clicked
        // by the page's own script), and only then sends the query. The warm is
        // once per process — a returning user's session is already formed.
        //
        // Generic: the root is derived from the host Pop is already navigating
        // to, there is no fallback engine, and no site is named here. The warm
        // runs on the FIRST lookup of this process, unconditionally and
        // deterministically — never re-formed later in the same process. If the
        // session cannot be formed (no network, a consent control that is not
        // clickable), the lookup proceeds anyway and reports whatever wall it
        // actually hit — it never returns silently empty.
        // Timed, not rendered: how much of this lookup was the session warm.
        // `nil` when the warm was skipped, which is what pre-warming at launch
        // produces — the difference between the two numbers IS the pre-warm.
        var warmMs: Int?
        if ProcessInfo.processInfo.environment["POP_WARM_SESSION"] != "0" {
            let warmStart = Date()
            await warmSession(host: URL(string: url)?.host ?? "")
            warmMs = Int(Date().timeIntervalSince(warmStart) * 1000)
        }
        defer {
            TurnMetrics.shared.recordLookup(
                totalMs: Int(Date().timeIntervalSince(lookupStarted) * 1000),
                warmMs: warmMs
            )
        }
        _ = await browser.navigate(url, activatingPane: false)
        try? await Task.sleep(for: .seconds(settleDelay))

        let script = extractionScript(query: trimmed)
        let json = await evaluate(browser.webView, script, timeout: extractionTimeout)
        let parsed = parse(json)
        let domChars = parsed.domChars
        // Page candidates are surfaced ONLY when a declared slot is missing, and
        // only as suggestions. A web lookup declares no slots, so this is always
        // empty: no scraped token can ever reach user-facing text.
        let candidates: [String] = []

        let answerRaw = parsed.answer
        var answer = answerRaw
        if answer.count > answerCap {
            answer = String(answer.prefix(answerCap)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let host = browser.webView.url?.host ?? URL(string: url)?.host ?? ""
        let title = parsed.title.isEmpty ? "(untitled)" : parsed.title
        let path = browser.webView.url?.path ?? "/search"
        let hostPath = (host.isEmpty ? "google.com" : host)
            .replacingOccurrences(of: "www.", with: "", options: [.anchored, .caseInsensitive])
            + (path.isEmpty ? "" : path)
        let payloadChars = answer.count
        let marker = "web: \(hostPath) \u{2014} \(payloadChars) chars"

        // HONESTY ORDER: an EMPTY answer is decided FIRST. Reporting "listed
        // fares" for a query that produced no text at all is a false claim — the
        // price tokens were scraped from the page shell, not from an answer, so
        // a rejected region (relation test) or a wall must say so plainly.
        let provenance: String
        if answer.isEmpty {
            provenance = parsed.blocked
                ? "a wall page was served, not a result \u{2014} query: \"\(trimmed)\""
                : "no extractable result text \u{2014} query: \"\(trimmed)\""
        } else if parsed.hasPrice {
            let sample = parsed.priceSample.isEmpty ? "" : " (\(parsed.priceSample))"
            provenance = "listed fares (\"starting from\"), not live availability\(sample) \u{2014} query: \"\(trimmed)\""
        } else {
            provenance = "search result text, not verified live \u{2014} query: \"\(trimmed)\""
        }

        let result = WebLookupResult(
            query: trimmed,
            answerExcerpt: answer,
            answerPrevChar: parsed.answerPrevChar,
            answerNextChar: parsed.answerNextChar,
            answerLocated: parsed.answerLocated,
            relationApplied: parsed.relationApplied,
            relationPassed: parsed.relationPassed,
            sourceHost: host,
            sourceTitle: title,
            provenance: provenance,
            inferredNotInQuery: parsed.inferred,
            declaredSlots: declared,
            missingSlots: missing,
            slotCandidates: candidates,
            wall: parsed.wall,
            marker: marker,
            domChars: domChars,
            payloadChars: payloadChars,
            usedURL: browser.webView.url?.absoluteString ?? url,
            locSource: location?.source.rawValue ?? LocationSource.serp.rawValue,
            locCity: location?.city ?? "",
            locMethod: method,
            locEmbedded: location != nil && !method.isEmpty
        )
        // The marker lands in Pop's own panel / action log. It never touches the
        // user's browser chrome.
        ProviderTestSeams.shared.lastWebMarker = marker
        // The CALLER-DECLARED slots and the missing subset, recorded where the
        // deterministic ask (in `ChatController.finish`) and the ask-honesty
        // probe can both read them. These — and ONLY these — can produce an ask.
        ProviderTestSeams.shared.lastDeclaredSlots = declared
        ProviderTestSeams.shared.lastMissingSlots = missing
        ProviderTestSeams.shared.lastSlotCandidates = candidates
        // LOW-CONFIDENCE metadata, logs only: the generic page-entity detector's
        // output. `finish` deliberately does not read this, so it cannot reach
        // the user.
        ProviderTestSeams.shared.lastInferredNotInQuery = parsed.inferred
        print("ACTION_LOG web_lookup \(marker)")
        print("WEB_LOOKUP_MARKER=\(marker)")
        print("WEB_LOOKUP_DECLARED_SLOTS="
            + declared.joined(separator: " | "))
        print("WEB_LOOKUP_RELATION_APPLIED=\(parsed.relationApplied)")
        print("WEB_LOOKUP_RELATION_PASSED=\(parsed.relationPassed)")
        print("WEB_LOOKUP_MISSING_SLOTS="
            + missing.joined(separator: " | "))
        print("WEB_LOOKUP_SLOT_CANDIDATES="
            + candidates.joined(separator: " | "))
        print("WEB_LOOKUP_INFERRED_NOT_IN_QUERY_LOWCONF="
            + parsed.inferred.joined(separator: " | "))
        fflush(stdout)
        browser.logAction(marker)
        return result
    }

    // MARK: - JSON plumbing

    private struct Parsed {
        var blocked = false
        var wall = ""
        var domChars = -1
        var answer = ""
        var answerPrevChar = ""
        var answerNextChar = ""
        var answerLocated = false
        var relationApplied = false
        var relationPassed = false
        var inferred: [String] = []
        var hasPrice = false
        var priceCount = 0
        var priceSample = ""
        var title = ""
    }

    private static func parse(_ json: String) -> Parsed {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Parsed() }
        var out = Parsed()
        out.blocked = (object["blocked"] as? Bool) == true
        out.wall = (object["wall"] as? String) ?? ""
        out.domChars = (object["domChars"] as? Int) ?? -1
        out.answer = (object["answer"] as? String) ?? ""
        out.answerPrevChar = (object["answerPrevChar"] as? String) ?? ""
        out.answerNextChar = (object["answerNextChar"] as? String) ?? ""
        out.answerLocated = (object["answerLocated"] as? Bool) == true
        out.relationApplied = (object["relationApplied"] as? Bool) == true
        out.relationPassed = (object["relationPassed"] as? Bool) == true
        out.inferred = (object["inferred"] as? [String]) ?? []
        out.hasPrice = (object["hasPrice"] as? Bool) == true
        out.priceCount = (object["priceCount"] as? Int) ?? 0
        out.priceSample = (object["priceSample"] as? String) ?? ""
        out.title = (object["title"] as? String) ?? ""
        return out
    }

    /// One `evaluateJavaScript` with a hard deadline, off the main run loop.
    /// The slot pattern (shared with `BrowserController.call`) is what makes a
    /// page that never answers a TIMED-OUT result rather than a hang: the async
    /// eval does not observe cancellation, so racing it inside a task group
    /// would wait for the page, which is the exact failure the deadline exists
    /// to prevent.
    private static func evaluate(
        _ webView: WKWebView,
        _ script: String,
        timeout: TimeInterval
    ) async -> String {
        let slot = JSResultSlot()
        slot.arm(after: timeout)
        Task { @MainActor in
            do {
                let value = try await webView.evaluateJavaScript(script)
                if let value, !(value is NSNull) {
                    slot.finish(String(describing: value))
                } else {
                    slot.finish("")
                }
            } catch {
                slot.finish("EVAL_ERROR: \(error.localizedDescription)")
            }
        }
        return await slot.next() ?? "(eval timed out)"
    }

    // MARK: - The generic extraction script

    /// No site-specific selectors anywhere: the whole script reads
    /// `document.body.innerText` and reasons about the query's own terms.
    /// Runs the REAL extraction script against whatever page the lookup webview is
    /// currently showing and reports the relation verdict it reached.
    ///
    /// Exists so the morphology probe measures the shipped rule rather than a
    /// re-implementation of it: a probe that rebuilt the pattern would only prove
    /// the probe agrees with itself.
    static func relationVerdict(
        query: String,
        on webView: WKWebView
    ) async -> (applied: Bool, passed: Bool, answer: String) {
        let json = await evaluate(webView, extractionScript(query: query), timeout: extractionTimeout)
        let parsed = parse(json)
        return (parsed.relationApplied, parsed.relationPassed, parsed.answer)
    }

    /// The extraction script. Internal rather than private so the morphology
    /// probe above can drive it against fixture text.
    static func extractionScript(query: String) -> String {
        let body = #"""
        (function () {
          var q = __QUERY__;
          var text = (document.body && document.body.innerText) ? document.body.innerText : "";
          var lower = text.toLowerCase();
          // Declared HERE, before the content terms exist: a `var` declaration
          // with an initialiser re-runs at its own line, so declaring these next
          // to the extraction state silently RESET the values assigned earlier
          // in the function, which is how `relationApplied` always read false.
          var relationApplied = false, relationPassed = false;

          // --- wall / consent / captcha detection ---
          // A wall STRING is not the same as a wall PAGE. A results page also
          // carries the no-JS fallback banner ("Enable JavaScript and then reload
          // the page") alongside a complete AI Overview — treating that banner
          // as the whole page threw away a real answer (measured: "who won the
          // match yesterday", DOM 2494 chars, wall tripped, payload 0, while the
          // page plainly read "Check the OneFootball or Cricinfo for full
          // scores..."). So the string only COUNTS as a wall when the page
          // yields no extractable result on its own; `blocked` is settled after
          // extraction below. A genuine captcha/consent page extracts nothing
          // and is still reported as a wall.
          var walls = ["before you continue", "consent", "unusual traffic", "enable javascript",
            "if you are not redirected", "are you a robot", "verify you are human", "captcha",
            "access denied", "unusual activity", "checking your browser",
            "confirm you're not a robot", "we just need to make sure"];
          var wallHit = false, wall = "";
          for (var i = 0; i < walls.length; i++) {
            var j = lower.indexOf(walls[i]);
            if (j !== -1) {
              wallHit = true;
              wall = text.substring(Math.max(0, j - 40), j + 280).replace(/\s+/g, " ").trim();
              break;
            }
          }

          // --- query content terms ---
          // Interrogatives, auxiliaries and pronouns are NOT content terms: an
          // answer region is not required to repeat the question word back.
          // "who" was missing here, so the relation test demanded that every
          // candidate region contain the literal word "who" and threw away a
          // real answer that plainly answered it (measured: "who won the match
          // yesterday" -> 0 payload on a page whose AI Overview read "Check the
          // OneFootball or Cricinfo for full scores..."). This is a generic
          // English function-word list — no site, place or domain knowledge.
          var stop = {what:1,whats:1,is:1,the:1,and:1,or:1,to:1,in:1,of:1,for:1,on:1,at:1,
            my:1,me:1,you:1,it:1,this:1,that:1,how:1,when:1,where:1,which:1,are:1,do:1,does:1,
            can:1,could:1,will:1,would:1,a:1,an:1,i:1,s:1,t:1,
            who:1,whom:1,whose:1,why:1,was:1,were:1,been:1,being:1,am:1,should:1,
            must:1,may:1,might:1,has:1,have:1,had:1,shall:1,did:1};
          var terms = [];
          var qparts = q.toLowerCase().replace(/[^a-z0-9\u00c0-\u024f]+/g, " ").split(" ");
          for (var p = 0; p < qparts.length; p++) {
            var w = qparts[p];
            if (w.length >= 3 && !stop[w] && terms.indexOf(w) === -1) { terms.push(w); }
          }

          // The relevance guard is LIVE whenever the query has content terms to
          // test, whether or not any of them were found on the page. Reported
          // from here, not from inside the extraction block: a nonsense query
          // never reaches that block (no anchor), and that must still read as
          // "the test was applied and rejected everything", not "test inactive".
          relationApplied = terms.length > 0;

          // Collapse whitespace and strip the echoed query: a no-results page
          // prints the query back, and that echo must never become "the answer".
          function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }
          var scan = text.replace(/\s+/g, " ");
          if (q.trim().length >= 4) {
            scan = scan.replace(new RegExp(esc(q.trim()), "gi"), " ");
          }
          // Collapse AGAIN: substituting the echoed query with " " can leave a
          // double space, and every later offset into `scan` depends on there
          // being exactly one space between tokens.
          scan = scan.replace(/\s+/g, " ").trim();
          var scanLower = scan.toLowerCase();
          // ONE shared term pattern for the density scorer and the relation
          // test, so the region they agree on is judged by the same rule. If
          // these two ever disagree, the anchor is picked on exact literals and
          // then failed on inflections, which is how a real answer was lost.
          function termRe(term) {
            return new RegExp("\\b" + esc(term) + "(s|es|ed|ing)?\\b");
          }
          function near(pos, half) {
            var from = Math.max(0, pos - half), to = Math.min(scan.length, pos + half);
            var seg = scanLower.substring(from, to);
            var n = 0;
            for (var i = 0; i < terms.length; i++) {
              if (termRe(terms[i]).test(seg)) { n++; }
            }
            return n;
          }
          var anchor = -1, bestN = 0;
          for (var t = 0; t < terms.length; t++) {
            var re = new RegExp("\\b" + esc(terms[t]) + "(s|es|ed|ing)?\\b", "g");
            var mm;
            while ((mm = re.exec(scanLower)) !== null) {
              var sc = near(mm.index, 200);
              // Relevance only: the DENSEST region wins, first one on a tie.
              // A later-region tie-break was tried here and reverted: it moved
              // the window off the answer on real queries ("how tall is mount
              // everest" -> 0 chars). Staleness is left to be MEASURED by
              // --test-excerpt-quality rather than guessed at in the extractor.
              if (sc > bestN) { bestN = sc; anchor = mm.index; }
              if (mm.index === re.lastIndex) { re.lastIndex++; }
            }
          }
          var noResults = /did not match any documents|no results found|didn't match any|no results containing|make sure all words are spelled/.test(lower);
          var answer = "";
          var answerPrevChar = "", answerNextChar = "";
          var answerLocated = false;
          var sentenceTrimmed = "", wordTrimmed = "";
          if (!noResults && anchor !== -1 && bestN > 0) {
            // BOUNDARY-AWARE WINDOW. A hard character range cut mid-word and
            // mid-sentence (measured: "C. Heavy Rain\u2026Sin", "pected. Snowfall
            // 0.0mm\u2026", "ages Videos Maps"). Pure text processing on the
            // generic extraction \u2014 no site knowledge. Two candidate ends are
            // computed from ONE window and the relation test below picks:
            //   1. start: advance to the next whitespace, so the window never
            //      begins mid-token (both candidates share it);
            //   2. `sentenceTrimmed`: cut back to the LAST sentence terminator
            //      (. ! ? \u2026) inside the window;
            //   3. `wordTrimmed`: cut back to the last whitespace \u2014 a complete
            //      word boundary just before the cap.
            // The sentence end is PREFERRED, but not at the price of the answer:
            // a sentence can end before the region stops carrying the query's
            // terms, and the relation test would then discard a real result
            // (measured: "how tall is mount everest" fell to 0 chars). So the
            // relation test runs on the sentence trim first and falls back to the
            // word trim, which is still a boundary-clean excerpt.
            var start = Math.max(0, anchor - 140);
            // Walk to the start of the NEXT word, in three steps, because each
            // guards a different way the raw offset lands badly:
            //   1. if the previous character is a word character we are INSIDE a
            //      token, so skip to its end (mid-word cut otherwise);
            //   2. skip separators/glyphs, or the window opens on "/" or "|";
            //   3. skip whitespace, or the head begins with a space.
            function isWordChar(ch) { return /[\p{L}\p{N}]/u.test(ch); }
            if (start > 0 && isWordChar(scan.charAt(start - 1))) {
              while (start < scan.length && isWordChar(scan.charAt(start))) { start++; }
            }
            while (start < scan.length && !isWordChar(scan.charAt(start))) { start++; }
            while (start < scan.length && /\s/.test(scan.charAt(start))) { start++; }
            // The window is an EXACT substring of `scan` — no re-collapse and no
            // leading trim — so `windowStart + any prefix offset` is a real
            // offset and `scan.substr(at, answer.length) === answer` holds. The
            // earlier version re-collapsed whitespace inside the window and
            // trimmed it, which silently shifted every character and made the
            // neighbour locate fail on excerpts that were perfectly fine.
            var windowStart = start;
            var window = scan.substring(start, start + 640);
            if (window.length > 600) { window = window.substring(0, 600); }
            // SERP NAVIGATION RUN, detected GENERICALLY: a leading run of short
            // bare words carrying no sentence punctuation ("All News Images Maps
            // Books Search tools"), which is menu chrome, never the answer. No
            // site is named and no token list is hardcoded — the pattern is
            // "N consecutive alphabetic tokens of <= 7 letters with no
            // sentence punctuation in the run". A short first word on its own
            // ("Booking.com", "Flight tracker") is NOT a run, because the run
            // requires >= NAV_RUN_MIN tokens.
            var NAV_RUN_MIN = 4;
            function navRunLength(s) {
              // Leading separator glyphs (a close button, a caret, a bullet) sit
              // BEFORE the run and must not stop it being measured.
              var lead = /^[^\p{L}\p{N}]+/u.exec(s);
              var body = lead ? s.substring(lead[0].length) : s;
              var toks = body.split(" ");
              var n = 0;
              for (var t2 = 0; t2 < toks.length; t2++) {
                var w = toks[t2];
                if (!/^[A-Za-z]{1,7}$/.test(w)) { break; }
                n++;
              }
              return n;
            }
            var headRun = navRunLength(window);
            if (headRun >= NAV_RUN_MIN) {
              // Drop the chrome run, and with it any leading separator run.
              // Recompute the origin precisely: skip the chrome tokens, the
              // spaces between them, and any separator characters, counting the
              // exact characters removed from `scan`.
              var probe = windowStart;
              while (probe < scan.length && /\s/.test(scan.charAt(probe))) { probe++; }
              // Separators/glyphs that sit BEFORE the run ("×", "›", "|").
              while (probe < scan.length && !/[\p{L}\p{N}]/u.test(scan.charAt(probe))) {
                probe++;
              }
              for (var c2 = 0; c2 < headRun; c2++) {
                while (probe < scan.length && !/\s/.test(scan.charAt(probe))) { probe++; }
                while (probe < scan.length && /\s/.test(scan.charAt(probe))) { probe++; }
              }
              // Skip separators/glyphs generically ("/", "×", "›", "|", "-"),
              // not a fixed class: the run can be followed by a path separator
              // and a window that opens on "/" is a mid-path cut.
              while (probe < scan.length && !isWordChar(scan.charAt(probe))) {
                probe++;
              }
              windowStart = probe;
              window = scan.substring(windowStart, windowStart + 640);
              if (window.length > 600) { window = window.substring(0, 600); }
            }
            var cut = -1;
            for (var e = 0; e < window.length; e++) {
              var ch = window.charAt(e);
              if (ch === "." || ch === "!" || ch === "?" || ch === "\u2026") {
                // A "." inside a URL or a decimal is punctuation of the TOKEN,
                // not of the sentence ("www.accuweather.", "3.14mm"), so it is
                // not a sentence end. Generic: the token ending at this dot must
                // not already contain a dot.
                if (ch === ".") {
                  var tk = "";
                  for (var b = e - 1; b >= 0 && !/\s/.test(window.charAt(b)); b--) {
                    tk = window.charAt(b) + tk;
                  }
                  // A dot that belongs to a URL or a decimal is punctuation of
                  // the TOKEN. That covers both the interior dot ("accuweather")
                  // and the TRAILING one after a bare host ("www.", "www.bbc.")
                  // — the token before it is itself a host fragment.
                  if (tk.indexOf(".") !== -1) { continue; }
                  if (e + 1 < window.length && !/\s/.test(window.charAt(e + 1))
                      && window.charAt(e + 1) !== "!" && window.charAt(e + 1) !== "?"
                      && window.charAt(e + 1) !== "\u2026") { continue; }
                }
                cut = e;
              }
            }
            var lastSpace = window.lastIndexOf(" ");
            var wordEnd = lastSpace > 0 ? window.substring(0, lastSpace) : window;
            // A candidate must not END on a dangling URL/domain fragment: the
            // cap or a cut can land inside a host ("... www.", "... www.bbc."),
            // and that is a reference cut in half, not a boundary. Detected
            // structurally — a trailing token that still carries a dot, or the
            // universal bare host prefix "www" — so no site is named.
            function endsOnHostFragment(s) {
              var t = s.split(" ").pop() || "";
              t = t.replace(/[.\u2026]+$/, "");
              if (t.toLowerCase() === "www") { return true; }
              return t.indexOf(".") !== -1;
            }
            // THE TAIL MUST LAND ON A BOUNDARY INSIDE THE CAP. When the 600-char
            // cap cuts mid-sentence there may be no terminator left at all, and
            // taking the window as-is ended the excerpt mid-URL
            // ("www.accuweather.", "meteofor.") or mid-token — exactly what the
            // gate flags. So: prefer the last sentence terminator; otherwise the
            // last whitespace; then keep backing up a word at a time for as long
            // as the tail is still a host fragment. The result is
            // boundary-clean by construction, and NEVER empty just because the
            // first candidate happened to land in a URL (which is what used to
            // blank both candidates and lose the whole answer).
            var boundaryEnd = (cut !== -1 && cut < window.length - 1)
              ? window.substring(0, cut + 1)
              : wordEnd;
            var guard = 0;
            while (endsOnHostFragment(boundaryEnd) && boundaryEnd.length > 0
                   && guard++ < 8) {
              var sp = boundaryEnd.lastIndexOf(" ");
              boundaryEnd = sp > 0 ? boundaryEnd.substring(0, sp) : "";
            }
            // EXACT prefix of `window` — no trim, no re-collapse — so the
            // neighbour locate below stays byte-accurate.
            sentenceTrimmed = boundaryEnd;
            wordTrimmed = boundaryEnd;
          }
          // RELATION TEST — generic, no site-specific rules. A candidate region
          // only counts as a result if the query's content terms ACTUALLY appear
          // in it. Page chrome (navigation labels, a "did you mean"/"showing
          // results for" correction) can echo one or two query terms without the
          // page being about the query at all — measured: a nonsense query
          // returned 599 chars of navigation chrome as an "answer". Requiring
          // EVERY content term to appear in the extracted region is the
          // principled line: a region unrelated to the query, or related only
          // through the search engine's own correction of it, yields no answer.
          function termsPresent(cand) {
            if (cand.length === 0) { return false; }
            var lower = cand.toLowerCase();
            for (var rt = 0; rt < terms.length; rt++) {
              // INFLECTIONS ONLY, never an arbitrary suffix. The earlier
              // `\bterm[a-z]{0,3}\b` also admitted "wonder" for "won", which let
              // a region about the wrong subject pass. The leading `\b` still
              // anchors the start of the word (so "unmatched" does not match
              // "match"), and only the real English inflections are allowed:
              // a page answers "matches" where the question said "match", while
              // it must not answer "wonder" where the question said "won".
              var re = new RegExp("\\b" + esc(terms[rt]) + "(s|es|ed|ing)?\\b");
              if (!re.test(lower)) { return false; }
            }
            return true;
          }
          if (sentenceTrimmed.length > 0 || wordTrimmed.length > 0) {
            // THE RELATION TEST BELONGS TO THE REGION, NOT TO THE EXCERPT. It
            // answers "is this part of the page about the query?", and the
            // 600-char WINDOW is the region the term-density search selected for
            // the query. Re-running it on the boundary-trimmed excerpt conflated
            // two different things and threw away real answers: the trim is
            // shorter, so a term sitting past the trim read as "this region is
            // not about the query" (measured: "who won the match yesterday" \u2014
            // the AI Overview region reads "Check the OneFootball or Cricinfo for
            // full scores, as yesterday's matches covered numerous sports", which
            // answers the question without repeating the word "won"). So: validate
            // the window, then take the best BOUNDARY-CLEAN prefix of it.
            var regionOK = terms.length === 0 || termsPresent(window);
            relationPassed = regionOK;
            // BEHAVIOUR (a): a region that shares no content term with the query
            // is a NO-ANSWER, not low-confidence text. There is deliberately no
            // fallback that resurrects it below: the previous
            // `if (answer.length === 0) { answer = wordTrimmed ... }` line made
            // this whole test dead code, so a window unrelated to the query was
            // still returned as an "answer". Silence would be dishonest here —
            // an empty payload with the honest provenance ("no extractable
            // result text") is what the caller needs to degrade.
            answer = regionOK ? (sentenceTrimmed.length > 0 ? sentenceTrimmed : wordTrimmed) : "";
            // RAW NEIGHBOUR EVIDENCE, not a verdict: the probe re-derives the
            // boundary decision in Swift from these two characters, so the gate
            // never has to trust a boolean this script computed for itself.
            // Read at REAL offsets (both candidates are prefixes of the live
            // window, which is a prefix of `scan` from `windowStart`) rather than
            // by searching for the answer text, which a trim can invalidate.
            // `answerLocated` is reported EXPLICITLY so a failed locate can
            // never masquerade as "the page had nothing either side": the probe
            // gates on it and FAILS when it is false.
            answerLocated = answer.length > 0;
            if (answerLocated) {
              // ROBUST LOCATE. The exact byte-offset check is tried first; if the
              // answer was re-spaced anywhere (the Swift side trims, and the page
              // can carry its own non-breaking/ideographic spaces), fall back to
              // scanning forward in `scan` for the same text with BOTH sides
              // whitespace-normalised, so an incidental space cannot make the
              // excerpt look unlocatable. The comparison is still the extractor
              // checking itself against the text it extracted from, and a genuine
              // miss still reports `located: false`.
              var at = -1;
              if (windowStart >= 0 && windowStart + answer.length <= scan.length
                  && scan.substr(windowStart, answer.length) === answer) {
                at = windowStart;
              } else {
                function squeeze(s) { return s.replace(/[\s\u00a0\u3000]+/g, " ").trim(); }
                var target = squeeze(answer);
                var hay = squeeze(scan);
                var found = hay.indexOf(target);
                if (found !== -1 && target.length > 0) {
                  // Map the normalised index back to a `scan` offset by walking
                  // the same way the normalisation folded runs of whitespace.
                  var seen = 0, raw = 0, i = 0;
                  while (i < scan.length && seen < found) {
                    if (/[\s\u00a0\u3000]+/.test(scan.charAt(i))) {
                      while (i < scan.length && /[\s\u00a0\u3000]+/.test(scan.charAt(i))) { i++; }
                      seen += 1; continue;
                    }
                    i++; seen += 1;
                  }
                  raw = i;
                  at = raw;
                }
              }
              if (at >= 0 && at < scan.length) {
                answerPrevChar = at > 0 ? scan.charAt(at - 1) : "";
                var after = at + answer.length;
                answerNextChar = after < scan.length ? scan.charAt(after) : "";
              } else {
                answerLocated = false;
              }
            }
          }

          // --- price-like tokens: provenance honesty, and what makes a result
          //     "listed fares" rather than "live availability" ---
          var priceRe = /(?:s?\$|sgd|usd|us\$|\u20ac|\u00a3)\s?[0-9][0-9,\.]*/gi;
          var priceSet = {};
          var pm;
          while ((pm = priceRe.exec(text)) !== null) {
            priceSet[pm[0].replace(/\s+/g, "").toUpperCase()] = true;
          }
          var priceKeys = Object.keys(priceSet);
          var priceCount = priceKeys.length;
          var hasPrice = priceCount > 0;
          var priceSample = priceKeys.slice(0, 3).join(", ");

          // --- ASK-RULE: parameter-like tokens in the page, absent from the query ---
          var qNorm = " " + q.toLowerCase().replace(/[^a-z0-9\u00c0-\u024f]+/g, " ")
            .replace(/\s+/g, " ").trim() + " ";
          function inQuery(s) {
            var n2 = " " + s.toLowerCase().replace(/[^a-z0-9\u00c0-\u024f]+/g, " ")
              .replace(/\s+/g, " ").trim() + " ";
            return qNorm.indexOf(n2) !== -1;
          }
          var uiStop = {search:1,settings:1,sign:1,about:1,help:1,privacy:1,terms:1,feedback:1,
            images:1,videos:1,maps:1,news:1,shopping:1,more:1,tools:1,all:1,account:1,google:1,
            results:1,next:1,previous:1,filters:1,people:1,also:1,ask:1,related:1,searches:1,
            flights:1,hotels:1,explore:1,overview:1,reviews:1,photos:1,menu:1,close:1,share:1,
            save:1,report:1,advertisement:1,sponsored:1,skip:1,accessibility:1,language:1,
            united:1,states:1,cancel:1,done:1,round:1,trip:1,one:1,way:1,nonstop:1,airline:1,
            airlines:1,departure:1,arrival:1,return:1,cheapest:1,best:1,top:1,non:1};
          var inferred = [];
          function sharesQueryWord(s) {
            var ws = s.toLowerCase().replace(/[^a-z0-9\u00c0-\u024f\s]+/g, " ").split(/\s+/);
            for (var i = 0; i < ws.length; i++) {
              var w = ws[i].replace(/s$/, "");
              if (w.length < 3) { continue; }
              for (var j = 0; j < terms.length; j++) {
                if (w === terms[j].replace(/s$/, "")) { return true; }
              }
            }
            return false;
          }
          function addInferred(s) {
            s = s.replace(/\s+/g, " ").replace(/[,;.]+$/, "").trim();
            if (!s || s.length < 3) { return; }
            // Glued navigation run-ons ("SettingsPrivacyTermsDark") are not
            // parameters; a value with no word boundary and no code shape is noise.
            if (s.indexOf(" ") === -1 && s.length > 12 && !/^[A-Z]{3}$/.test(s)) { return; }
            var key = s.toLowerCase();
            if (uiStop[key.split(" ")[0]]) { return; }
            if (inQuery(s)) { return; }
            // If any of its words already appears in the query, the page did NOT
            // invent it — it is anchored to what the user asked.
            if (sharesQueryWord(s)) { return; }
            for (var i = 0; i < inferred.length; i++) {
              var other = inferred[i].toLowerCase();
              if (other === key) { return; }
              if (other.indexOf(key) !== -1 || key.indexOf(other) !== -1) {
                if (key.length > other.length) { inferred[i] = s; }
                return;
              }
            }
            inferred.push(s);
          }
          // Place names following a PARAMETER cue. Generic, not site-specific.
          // Deliberately narrow: only cues that fill a required slot ("from X",
          // "origin: X"). A bare prose "in <City>" is not a parameter the page
          // filled, and surfacing it would make every location-less question
          // look like a missing-parameter question.
          var cueRe = /\b(?:from|departing|arriving|flying|origin|destination|where from)\s*:?\s+([A-Z][A-Za-z\u00c0-\u024f.'-]+(?:\s+[A-Z][A-Za-z\u00c0-\u024f.'-]+){0,3})/g;
          var m;
          while ((m = cueRe.exec(text)) !== null) { addInferred(m[1]); }
          // Dates are deliberately NOT inferred here. A result page is full of
          // dates that are RESULT DATA, not missing parameters (measured: a
          // weather page's 10-day forecast dates made every location-less
          // question look like a missing-parameter question). The ask-rule keys
          // on explicit parameter cues only.
          // Bare 3-letter codes are NOT inferred: a result page is full of
          // acronyms (measured: "MSN" from a "from MSN Weather" snippet), and a
          // guessed code is not worth the false positives. Place names after an
          // explicit parameter cue carry the ask-rule.
          // Fallback: an origin-style input's current value, found generically.
          var inputs = document.querySelectorAll("input[aria-label],input[placeholder]");
          for (var oi = 0; oi < inputs.length; oi++) {
            var el = inputs[oi];
            var lab = ((el.getAttribute("aria-label") || "") + " " + (el.getAttribute("placeholder") || "")).toLowerCase();
            if (/from|origin|where from|depart/.test(lab)) {
              var val = (el.value || "").trim() || (el.getAttribute("aria-label") || "").trim();
              if (val && !/^(where from|origin|from|depart)/i.test(val)) { addInferred(val); }
            }
          }

          // WALL RESOLUTION, after extraction. A wall STRING on a page that
          // still yields a real answer is chrome, not a wall: only a page that
          // produces NO extractable result is reported as blocked. This is what
          // recovers a real answer from a results page that carries the no-JS
          // banner, while a genuine consent/captcha page (which extracts
          // nothing) is still reported honestly as a wall.
          var blocked = wallHit && answer.length === 0;

          var out = {
            blocked: blocked,
            wall: wall,
            domChars: text.length,
            answer: answer,
            answerPrevChar: answerPrevChar,
            answerNextChar: answerNextChar,
            answerLocated: answerLocated,
            relationApplied: relationApplied,
            relationPassed: relationPassed,
            inferred: inferred,
            hasPrice: hasPrice,
            priceCount: priceCount,
            priceSample: priceSample,
            title: document.title || ""
          };
          return JSON.stringify(out);
        })()
        """#
        return body.replacingOccurrences(of: "__QUERY__", with: BrowserController.jsString(query))
    }
}
