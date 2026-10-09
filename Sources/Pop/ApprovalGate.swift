import CoreGraphics
import Foundation

/// What the user decided about one mutating tool call.
enum ApprovalVerdict: Sendable, Equatable {
    /// Run it. Carries the arguments to use, which are the EDITED ones when the
    /// user changed them in the card — running the model's original argument
    /// bag after the user edited it would silently ignore their correction.
    case run(arguments: JSONValue, edited: Bool)
    /// Refused. The reason travels back to the model as tool text.
    case deny(String)
    /// Nobody answered inside the hard window. Treated as a DENY: silence is
    /// not consent, and an unattended app must never run a mutating tool.
    case timeout

    /// Marker printed after `APPROVAL_REQUESTED`.
    var marker: String {
        switch self {
        case .run(_, let edited): edited ? "edit" : "run"
        case .deny: "deny"
        case .timeout: "timeout"
        }
    }

    /// True when the tool may execute.
    var isApproved: Bool {
        if case .run = self { return true }
        return false
    }
}

/// The one-click gate in front of every MUTATING tool.
///
/// Read-only tools never reach this type. A mutating tool is presented as a
/// card, the page posts a verdict back, and the suspended tool call resumes
/// with it — bounded by `hardTimeout`, because a gate that can wait forever is
/// indistinguishable from a hang, and an unanswered prompt in a floating
/// assistant would leave the transcript open forever.
///
/// Isolation is explicit: `awaitVerdict` parks inside the task group for the
/// whole window, so the checker's own cancellation only unblocks the inner
/// task — never the requester.
final class ApprovalGate: @unchecked Sendable {
    static let shared = ApprovalGate()

    /// Hard ceiling on one request. After this the verdict is `.timeout`.
    static let hardTimeout: TimeInterval = 120

    /// The marker a TIMED-OUT gated request carries in its result text. A plain
    /// deny and a timeout read the same to the user ("not approved"), but the
    /// agent loop must tell them apart: a timeout means the user was ASKED and
    /// did not answer, so re-issuing the same kind of command just stacks cards.
    static let timeoutMarker = "GATED_TIMEOUT"

    private static let lock = NSLock()
    private static var waiters: [String: CheckedContinuation<ApprovalVerdict, Never>] = [:]
    /// Verdicts that arrived before the waiter was parked.
    ///
    /// The card is pushed BEFORE the caller parks, and the page can answer
    /// inside that window (an instant tap, or a probe answering from the sink).
    /// Dropping such a verdict would hang the tool until the 120s deadline for
    /// no reason, so an early answer is kept and consumed on registration.
    private static var early: [String: ApprovalVerdict] = [:]
    private static let earlyLimit = 32
    /// The argument bag the MODEL sent, kept per request so a plain Run (which
    /// carries no arguments) resumes with what the card actually showed rather
    /// than with an empty object.
    private static var originals: [String: JSONValue] = [:]

    /// Where the card is pushed. Set by `ChatController`; `nil` (a headless
    /// probe, a launch before the page exists) still resolves — it just means
    /// nobody can see the card, so only the timeout can end it.
    var sink: (@Sendable (String) async -> Void)?

    /// How a finished decision is reported to the transcript. Driven from HERE
    /// rather than from the page message, because a TIMEOUT has no page message
    /// and the transcript must still say the card resolved.
    var resolution: (@Sendable (String, String) async -> Void)?

    /// Seconds the probe path waits. `POP_APPROVAL_TIMEOUT` exists so a probe can
    /// prove the timeout branch in seconds instead of two minutes; the shipped
    /// default stays 120s and nothing else can lower it.
    static var effectiveTimeout: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["POP_APPROVAL_TIMEOUT"],
           let value = TimeInterval(raw), value > 0 {
            return value
        }
        return hardTimeout
    }

    private init() {}

    /// The transcript wording for a standing-approval auto-run. Distinct from
    /// the manual "approved" so the transcript shows the act ran without a card.
    static let autoRunMarker = "approved (auto)"

    /// The tool classes the standing approval covers, BY NAME. Pure and static
    /// so a probe can truth-table it; `app_manage` is action-dependent.
    ///
    /// Covered: the reversible screen acts. NOT covered (always ask): `bash`,
    /// `write_file`, `edit_file`, `apply_patch`, `ui_type` (typing into a real
    /// browser can post content), and `app_manage` with action `quit`.
    static func autoRunnable(tool: String, action: String? = nil) -> Bool {
        switch tool {
        case "ui_click", "ui_scroll", "ui_key", "ui_ax":
            return true
        case "app_manage":
            // activate/open are reversible; a quit is not.
            return action == "activate" || action == "open"
        default:
            return false
        }
    }

    /// Whether the standing approval also clears the POINT/BOUNDS guard: a
    /// point-ful act must land inside a VISIBLE APP window. `ui_key`, `ui_ax`
    /// and `app_manage` have no point; `ui_scroll` without explicit x/y defaults
    /// to a visible window's centre, so it qualifies.
    private static func autoRunPointAllowed(tool: String, arguments: JSONValue) async -> Bool {
        let object = arguments.objectValue
        func intArg(_ key: String) -> Int? {
            guard let value = object[key] else { return nil }
            switch value {
            case .number(let double): return Int(double)
            case .string(let text): return Int(text)
            default: return nil
            }
        }
        switch tool {
        case "ui_click", "ui_scroll":
            guard let x = intArg("x"), let y = intArg("y") else {
                // ui_click's point is required, so a missing one is NOT
                // auto-runnable; ui_scroll omits x/y to use the window centre.
                return tool == "ui_scroll"
            }
            let bounds = await BrowserActions.visibleWindowBounds()
            return BrowserActions.pointIsAllowed(CGPoint(x: x, y: y), in: bounds)
        default:
            return true
        }
    }

    /// The composed standing-approval decision: class AND point guard.
    private static func autoRun(tool: String, arguments: JSONValue) async -> Bool {
        let action = arguments.objectValue["action"].flatMap { value -> String? in
            if case .string(let text) = value { return text }
            return nil
        }
        guard autoRunnable(tool: tool, action: action) else { return false }
        return await autoRunPointAllowed(tool: tool, arguments: arguments)
    }

    /// Presents `tool`/`arguments` and suspends until a verdict arrives.
    ///
    /// Every caller here is a remote-mutating tool (`PopTool.requiresApproval`);
    /// local actions never reach this gate and raise no card.
    func requestApproval(tool: String, arguments: JSONValue) async -> ApprovalVerdict {
        // STANDING APPROVAL (autonomy mode). The user asked Pop to carry an
        // instruction end-to-end, so a REVERSIBLE screen act inside the allowed
        // windows runs WITHOUT a card and WITHOUT pausing for jev. The user's
        // instruction IS the approval; the class + point/bounds guards below are
        // the safety line. Anything irreversible, out-of-bounds, or
        // content-posting falls through to the card as before.
        if let config = try? PopConfig.load(), config.autoRunScreenActions,
           await Self.autoRun(tool: tool, arguments: arguments) {
            print("APPROVAL_AUTORUN tool=\(tool)")
            fflush(stdout)
            await resolution?(tool, Self.autoRunMarker)
            return .run(arguments: arguments, edited: false)
        }
        let id = UUID().uuidString
        Self.remember(id: id, arguments: arguments)
        let preview = Self.preview(arguments)
        print("APPROVAL_REQUESTED tool=\(tool) id=\(id)")
        print("APPROVAL_ARGS_PREVIEW=\(preview)")
        fflush(stdout)
        // ADVISORY BEFORE THE PUSH, and ONLY when the user enabled jev. With it
        // off the card JSON is byte-identical to today. The fetch is bounded at
        // 3 s inside JevBridge and can never throw, so the verdict path below is
        // untouched: jev labels the card, it does not gate it.
        var jev: [String: Any]? = nil
        if let config = try? PopConfig.load(), config.jevEnabled {
            if let advisory = await JevBridge.advisory(
                goal: "Should the mutating tool \(tool) proceed?",
                question: "approve",
                options: [
                    "run": "let it run",
                    "edited": "run with edited arguments",
                    "deny": "deny"
                ]
            ) {
                let strength = advisory.probabilities[advisory.choice] ?? 0
                // The floor is the user's signal-to-noise control (SPEC §4.4
                // "thresholds"): below it the advisory is NOT shown at all —
                // `jev` stays nil so the card is byte-identical to the disabled
                // path. The service ANSWERED; only its confidence fell short.
                if JevBridge.belowThreshold(strength: strength, floor: config.jevThreshold) {
                    print("JEV_BELOW_THRESHOLD choice=\(JevBridge.sanitize(advisory.choice))"
                        + " strength=\(String(format: "%.2f", strength))"
                        + " floor=\(config.jevThreshold)")
                    fflush(stdout)
                } else {
                    jev = [
                        "choice": advisory.choice,
                        "strength": strength,
                        "available": true
                    ]
                }
            } else {
                jev = ["available": false]
            }
        }
        await sink?(Self.cardJSON(id: id, tool: tool, preview: preview, arguments: arguments, jev: jev))

        let timeout = Self.effectiveTimeout
        let verdict = await withTaskGroup(of: ApprovalVerdict.self) { group in
            group.addTask { await Self.awaitVerdict(id: id) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timeout
            }
            // First answer wins: the page's verdict, or the deadline.
            let first = await group.next() ?? .timeout
            group.cancelAll()
            Self.discard(id: id)
            return first
        }
        print("APPROVAL_VERDICT tool=\(tool) verdict=\(verdict.marker)")
        fflush(stdout)
        await resolution?(tool, Self.transcriptMarker(for: verdict))
        return verdict
    }

    /// Page -> Swift. Returns false for an unknown or already-resolved id.
    @discardableResult
    func submit(id: String, decision: String, arguments: JSONValue?) -> Bool {
        Self.lock.lock()
        let continuation = Self.waiters.removeValue(forKey: id)
        let verdict = Self.verdict(for: id, decision: decision, arguments: arguments)
        Self.lock.unlock()
        if let continuation {
            continuation.resume(returning: verdict)
            return true
        }
        // Nobody is parked yet: hold the answer for whoever is coming.
        Self.lock.lock()
        if Self.early.count < Self.earlyLimit { Self.early[id] = verdict }
        let held = Self.early[id] != nil
        Self.lock.unlock()
        return held
    }

    /// `id`-scoped write, kept synchronous so the lock is never held across an
    /// `await` (an unavailable-in-async-context lock is an error, not a warning,
    /// in the next language mode).
    private static func remember(id: String, arguments: JSONValue) {
        lock.lock()
        originals[id] = arguments
        lock.unlock()
    }

    /// Called with the lock held.
    private static func verdict(for id: String, decision: String, arguments: JSONValue?) -> ApprovalVerdict {
        switch decision {
        case "run":
            // No arguments on a plain Run means "exactly what the card showed".
            return .run(arguments: arguments ?? originals[id] ?? .object([:]), edited: false)
        case "edit":
            // An edit with nothing usable is not an approval: falling back to
            // the model's own arguments would run exactly what the user was
            // trying to change. Treat it as a refusal instead.
            if let arguments { return .run(arguments: arguments, edited: true) }
            return .deny("edit submitted with no arguments")
        default:
            return .deny("denied by user")
        }
    }

    /// Parks the caller. Cancelling this inner task (because the sibling won
    /// the race) simply unblocks the `withCheckedContinuation` without resuming
    /// anybody, so the parked continuation is never resumed twice.
    private static func awaitVerdict(id: String) async -> ApprovalVerdict {
        await withCheckedContinuation { continuation in
            lock.lock()
            // A verdict that landed while this task was starting wins outright;
            // registering first would make the caller resume it twice.
            if let held = early.removeValue(forKey: id) {
                lock.unlock()
                continuation.resume(returning: held)
                return
            }
            waiters[id] = continuation
            lock.unlock()
        }
    }

    /// Cleans up a waiter that lost the race to the deadline.
    ///
    /// It IS resumed, with `.timeout` — dropping a checked continuation
    /// unreleased is a runtime trap ("continuation leaked"), and a resume whose
    /// value nobody reads is harmless. The alternative (never registering until
    /// after the card is pushed) is what creates the early-verdict window.
    private static func discard(id: String) {
        lock.lock()
        let abandoned = waiters.removeValue(forKey: id)
        early.removeValue(forKey: id)
        originals.removeValue(forKey: id)
        lock.unlock()
        abandoned?.resume(returning: .timeout)
    }

    /// One-line, 120-char, single-line view of an argument bag. `write_file`
    /// and `edit_file` carry file CONTENT, so the full `stableString` that
    /// `TOOL_CALL` prints for read-only tools must never reach the log here.
    static func preview(_ arguments: JSONValue) -> String {
        let flattened = arguments.stableString()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(flattened.prefix(120))
    }

    static func cardJSON(
        id: String,
        tool: String,
        preview: String,
        arguments: JSONValue,
        jev: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = [
            "id": id,
            "tool": tool,
            "preview": preview,
            "risk": riskTag(for: tool),
            "arguments": arguments.foundationObject
        ]
        // The jev advisory, present ONLY when the feature is enabled. Absent (the
        // default) means the card is exactly what it was before jev existed.
        if let jev { payload["jev"] = jev }
        // THE SEND is the one card a person must actually read: a newline in
        // `ui_type` presses Return, which transmits to a real person. Name the
        // exact text and the window it will land in — the window title from the
        // LAST screen read, AS READ, never as the model intended. Typing without
        // a newline never reaches here (it is autonomous).
        if tool == "ui_type", case .string(let text) = arguments.objectValue["text"] ?? .null {
            let readTitle = ScreenOCR.lastFrontWindowTitle()
            let target = readTitle.isEmpty ? "the focused browser window" : readTitle
            payload["summary"] = "Send \"\(text)\" in \(target)?"
            payload["text"] = text
            payload["target"] = target
        }
        let data = try? JSONSerialization.data(withJSONObject: payload)
        guard let text = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return "{}" }
        return text
    }

    /// The transcript wording for a resolved card. `edited` is called out
    /// separately from `approved` because the arguments the model sent were NOT
    /// the arguments that ran, and the user should be able to see that.
    static func transcriptMarker(for verdict: ApprovalVerdict) -> String {
        switch verdict {
        case .run(_, let edited): edited ? "edited" : "approved"
        case .deny: "denied"
        case .timeout: "timed out"
        }
    }

    /// The one-word severity shown on the card. `bash` runs the user's real
    /// shell with their permissions, so it is always the loudest; every other
    /// gated tool names its own class, so a card for a click does not claim to
    /// change files.
    static func riskTag(for tool: String) -> String {
        if tool == "bash" { return "runs a real shell" }
        return ToolRegistry.tool(named: tool)?.riskLabel ?? "changes files"
    }
}
