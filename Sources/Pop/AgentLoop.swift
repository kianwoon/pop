import Foundation

/// One tool round, as the loop sees it.
struct ToolRoundOutcome: Sendable {
    var name: String
    var ok: Bool
    var detail: String
}

/// PRODUCT-UI TURN SIGNALS, delivered by the loop to whoever renders the panel.
///
/// The measured defect this exists for: after the user hits return the panel
/// showed NOTHING for the 3-6s the first model call ran. Delivery only —
/// nothing here decides what the turn contains.
enum TurnUIEvent: Sendable, Equatable {
    /// The turn started. Emitted BEFORE the first provider call, so the status
    /// line can read "working…" from T0 rather than after the first token.
    case working
    /// The turn ended on the normal path. The page's own `chatDone`/`chatError`/
    /// `chatStopped` still own the terminal label.
    case ready
    /// A verified action's executor-composed receipt, e.g. `✓ Sent "hi" to …`.
    /// Rendered with NO model round between the verify step and the receipt.
    case confirmation(String)
    /// A one-line transcript NOTICE the loop pushes BETWEEN rounds — the jev
    /// run-state label. Rendered through the same one-liner sink as every other
    /// notice; it is the ONLY output of labeling, so it never changes the turn.
    case notice(String)
}

/// Drives a streaming turn and feeds tool results back until the model stops
/// asking for them.
///
/// Two shapes, one loop:
///   * A provider that does NOT execute tools itself (the OpenAI-shaped path)
///     emits `.toolCall`, and this loop runs the tool, appends the result as a
///     tool-role message and streams again — up to `maxRounds`.
///   * A provider that DOES execute tools (FoundationModels) has already run
///     them inside the session and re-emits `.toolCall` as a marker only; the
///     loop must not execute anything twice, so those events are passed through
///     and the round budget is not consumed.
///
/// A tool that fails returns its reason AS TEXT. The model has to read what
/// went wrong and recover; a thrown error would end the stream with a raw
/// failure the user sees instead of an answer.
/// Per-turn PLAN-EXEC telemetry, printed to STDOUT ONLY.
///
/// The user wants the speed numbers off-screen. This records how many provider
/// rounds a turn spent (`FM_CALLS_PER_TURN`), how much of it was plan
/// execution, and — when a step failed — how many model rounds followed the
/// failure (`ADAPT_ROUNDS`, which must stay at most one). It never reaches the
/// transcript; nothing here can call the bridge.
final class AgentLoopMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var start: Date?
    private var providerCalls = 0
    private var planExecSeen = false
    private var callsAtFailure: Int?

    func reset(at date: Date) {
        lock.lock()
        start = date
        providerCalls = 0
        planExecSeen = false
        callsAtFailure = nil
        lock.unlock()
    }

    func noteProviderCall() {
        lock.lock(); providerCalls += 1; lock.unlock()
    }

    func notePlanExec() {
        lock.lock(); planExecSeen = true; lock.unlock()
    }

    /// The FIRST time a whole-plan run comes back blocked, stamp the provider
    /// call count. Anything after it is an adaptation round.
    func notePlanExecFailed() {
        lock.lock()
        if callsAtFailure == nil { callsAtFailure = providerCalls }
        lock.unlock()
    }

    var fmCalls: Int { lock.lock(); defer { lock.unlock() }; return providerCalls }
    var planExecRan: Bool { lock.lock(); defer { lock.unlock() }; return planExecSeen }
    var adaptRounds: Int {
        lock.lock(); defer { lock.unlock() }
        guard let f = callsAtFailure else { return 0 }
        return max(0, providerCalls - f)
    }
    var noEndlessRetry: Bool { adaptRounds <= 1 }

    /// Prints the plan-exec lines, and only when a plan-exec ran: a one-shot
    /// turn has nothing to report.
    func report() {
        lock.lock()
        guard planExecSeen else { lock.unlock(); return }
        let ms = start.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let calls = providerCalls
        let adapt = callsAtFailure.map { max(0, providerCalls - $0) } ?? 0
        let between = ToolRegistry.executorModelRoundsBetweenSteps
        lock.unlock()
        print("PLAN_EXEC_TURN_MS=\(ms) FM_CALLS_PER_TURN=\(calls) EXECUTOR_ROUNDS_BETWEEN_STEPS=\(between) ADAPT_ROUNDS=\(adapt)")
        fflush(stdout)
    }
}

enum AgentLoop {
    /// The per-turn plan-exec telemetry, readable by a probe after a turn.
    static let metrics = AgentLoopMetrics()

    /// The tool-round ceiling for one turn.
    ///
    /// HISTORY: raised 4 → 6 because a PLANNED request spends rounds on the plan
    /// itself: `plan_update` (set the steps) → a real tool round →
    /// `plan_update` (statuses) → the answer is the fourth round, and a plan
    /// with two tool rounds in the middle would hit the old cap before it could
    /// report where it got to.
    ///
    /// RAISED 6 → 15 on MEASURED evidence: the richest supported workflow is a
    /// routed browser/computer-use turn, which spends ~2 rounds per plan step
    /// (an approval-free act + a verify `screen_read`) plus plan updates — a
    /// 5-step plan lands at ~12-14 rounds. A live LinkedIn-notifications turn was
    /// aborted at round 6 (`TOOL_ROUND_LIMIT reached rounds=6`, 77 s) while it
    /// was WORKING CORRECTLY — on the target page, reads returning real content
    /// (SCREEN_OCR_LINES=60, title=Notifications | LinkedIn). 15 leaves headroom
    /// for a 5-step plan.
    ///
    /// The cap stays HARD: a `plan_update` loop cannot run forever, and
    /// `TOOL_ROUND_LIMIT` still fires when it is reached — now with a
    /// user-visible notice (see the trip branch in `stream`), so hitting it is
    /// announced, never silent.
    ///
    /// A `plan_update` call does NOT end the turn. It is an ordinary tool round
    /// like any other — nothing in the loop treats it specially — so the model
    /// can interleave plan updates with `screen_read`/`web_lookup` and then
    /// answer, which is exactly the shape this ceiling has to leave room for.
    ///
    /// `maxRounds` is now the UNPLANNED floor, not the whole story: the loop's
    /// effective budget is PLAN-AWARE (`roundBudget(planSteps:)`). A turn that
    /// never plans — a chat question, a one-shot read — keeps this 15-round
    /// budget. A turn that DECLARES a plan gets budget proportional to that
    /// plan, because measured screen workflows scale with plan size: a job
    /// application form (10-20 fields) is 10-20 plan steps, each ~4 rounds
    /// (act + verify-read + interleaved `plan_update` + answer slack), so a
    /// 12-field form needs ~56 rounds. A fixed constant would always kill that
    /// honest work. The budget can only GROW within a turn, and a hard ceiling
    /// (`maxPlanAwareRounds`) still bounds a true runaway.
    static let maxRounds = 15

    /// The ABSOLUTE CEILING on a plan-aware budget. However large the DECLARED
    /// plan, the loop stops here — with the same `TOOL_ROUND_LIMIT` trip and
    /// the same continue notice — so a `plan_update` that loops cannot run
    /// forever. A model that declares 30 steps and then never finishes still
    /// hits a hard stop, it just gets room to try first.
    static let maxPlanAwareRounds = 60

    /// The per-step round cost, MEASURED against screen/app workflows: one act,
    /// one verify `screen_read`, one interleaved `plan_update`, plus slack for
    /// the answer. It is a SCALE factor, not a promise; the ceiling caps it.
    static let roundsPerPlanStep = 4

    /// The round budget for a turn, PLAN-AWARE.
    ///
    /// No plan (`nil`) keeps the chat floor `maxRounds` (15). A DECLARED plan of
    /// N steps gets `N * roundsPerPlanStep + 8`, floored at the chat budget and
    /// hard-CEILINGED at `maxPlanAwareRounds` (60). The `+ 8` is the plan-setup
    /// and answer overhead the measured histories show (a 5-step plan lands at
    /// 28; a 12-field job-application form at 56). The invariant: the budget
    /// scales with the DECLARED plan, not a magic constant — honest long work
    /// fits, true runaways still hit a hard ceiling and announce it.
    static func roundBudget(planSteps: Int?) -> Int {
        guard let planSteps else { return maxRounds }
        return max(maxRounds, min(maxPlanAwareRounds, planSteps * roundsPerPlanStep + 8))
    }

    /// The step count a `plan_update` reported, read from its model-facing
    /// summary ("plan recorded: N step(s)"). This is how the loop learns the
    /// DECLARED plan size that sizes the adaptive budget. A non-plan result
    /// (an error, or a whole-plan `run` receipt) returns `nil`.
    static func declaredPlanSteps(from result: String) -> Int? {
        guard let range = result.range(of: "plan recorded: ") else { return nil }
        let digits = result[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// THE PLAN NUDGE. A multi-step request that reaches a second tool round
    /// without the model ever calling `plan_update` is the measured failure
    /// this exists for: the work is happening with no visible plan. The loop
    /// injects this ONE system message into its local round messages and the
    /// model sees it for every remaining round of the turn. It is a plain
    /// string so the probe asserts the exact bytes, and it names NO task or
    /// domain — only the tool and its purpose.
    static let planNudge = "multi-step request: set your plan with plan_update"

    /// How many tool rounds may go by without a plan before the nudge fires.
    static let nudgeAfterRounds = 2

    /// THE GATED-TIMEOUT NUDGE. When the user does not answer an approval card,
    /// the gated request returns `.timeout` — silence, not consent. The measured
    /// failure: the model re-issued the same kind of gated command, stacking
    /// cards the user never approved. ONE system message per turn, injected the
    /// moment the first timeout lands (the plan-nudge pattern), steers it away
    /// from the blocked kind and toward the on-screen UI path. It names no task.
    static let gatedTimeoutNudge = """
        The user has not approved pending commands. Do NOT issue more commands \
        of that kind — use the on-screen UI path (ui_observe + ui_ax/app_manage), \
        or stop and ask the user directly.
        """

    /// THE RIGHT HAT, chosen by the turn's jev route. The brain has general tools
    /// but no domain persona; a routed turn is served by a brain that KNOWS the
    /// routed capability. Pure and total: an unknown/nil/chat route returns "" so
    /// nothing is injected. It changes no tool, no budget, no gate — only the
    /// thinking the model starts from.
    static func hat(for route: String?) -> String {
        BrainLoader.hat(for: route)
    }

    /// The GENERAL macOS-automation playbook, injected ONLY on a computer-use
    /// route. It supplies the domain thinking ONCE, not per-use-case tools: drive
    /// apps like a human, observe, act by identity (ref), verify. Names no task,
    /// app or setting. Sourced from `Resources/brain.md` (`BrainLoader`), so the
    /// thinking is data the user can edit without recompiling.
    static var macosPlaybook: String { BrainLoader.playbook }

    /// The ONE turn-start context injection: the hat (route-conditional) first,
    /// then the computer-use playbook, then the jev routing hint. Returns the
    /// messages untouched when there is nothing to inject (disabled/nil/chat), so
    /// the bytes are identical to the pre-hat behavior. The hat is logged once.
    static func injectTurnContext(choice: String?, into messages: [ChatMessage]) -> [ChatMessage] {
        let hatText = hat(for: choice)
        var lines: [String] = []
        if !hatText.isEmpty, let choice {
            lines.append("[\(choice)] \(hatText)")
            print("HAT_APPLIED route=\(choice)")
            fflush(stdout)
        }
        if choice == "computer-use" {
            lines.append(Self.macosPlaybook)
        }
        // POLICY LINES, from the same brain data file. Injected only on a ROUTED
        // turn, alongside the hat and playbook — the no-route path stays byte-
        // identical to before (nothing is injected), and when brain.md is
        // missing the fallback policies are served.
        if choice != nil {
            lines.append(contentsOf: BrainLoader.policies)
        }
        if let choice {
            lines.append(Self.routeContextLine(choice: choice))
        }
        guard !lines.isEmpty else { return messages }
        return Self.injectRouteHint(lines.joined(separator: "\n"), into: messages)
    }

    /// Executes a model-named tool and reports its outcome exactly once.
    ///
    /// The activity callback is `async` because the only real consumer hops to
    /// the main actor to render the transcript line, and a tool result is
    /// worthless if nothing showed the user that it ran.
    static func runTool(
        _ call: (name: String, arguments: JSONValue),
        onActivity: @escaping @Sendable (ToolRoundOutcome) async -> Void
    ) async -> String {
        let box = ActivityBox()
        let result = await ToolRegistry.execute(
            call,
            onActivity: { name, ok, detail in
                let outcome = ToolRoundOutcome(name: name, ok: ok, detail: detail)
                box.set(outcome)
                await onActivity(outcome)
            }
        )
        // A tool that never reached `execute` (unknown name) still gets an
        // activity line, so the transcript never shows a call with no outcome.
        if box.value == nil {
            let ok = !result.hasPrefix("ERROR:")
            await onActivity(ToolRoundOutcome(
                name: call.name,
                ok: ok,
                detail: String(result.prefix(200))
            ))
        }
        return result
    }

    static func toolMessage(id: String?, name: String, result: String) -> ChatMessage {
        ChatMessage(role: .tool, text: result, toolCallId: id)
    }

    /// The executor-composed receipt carried on the first line of a
    /// `PLAN_EXEC_CONFIRMED` result: `PLAN_EXEC_CONFIRMED: ✓ Sent "…"`.
    static func confirmationLine(_ result: String) -> String {
        let prefix = "PLAN_EXEC_CONFIRMED: "
        let first = result
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        return first.hasPrefix(prefix)
            ? String(first.dropFirst(prefix.count))
            : first
    }

    /// The current user turn's text, capped at 200 chars — the goal a run-state
    /// advisory is judged against. Empty when the request carries no user turn.
    static func turnGoal(from messages: [ChatMessage]) -> String {
        let text = messages.last { $0.role == .user }?.text ?? ""
        return String(text.prefix(200))
    }

    /// ONE run-state label (SPEC §4.4 use (c)), fired between rounds.
    ///
    /// AWAITS the advisory, bounded by `JevBridge.timeout` (3 s), so it can
    /// delay the NEXT round by at most that — never a running tool call. The
    /// result is a log line and, when a stall/drift clears the user's floor, one
    /// transcript notice. It returns the label token so a probe can assert it;
    /// it NEVER throws and NEVER touches control flow: a nil advisory is just
    /// `skipped=unavailable`, and the loop proceeds identically.
    @discardableResult
    static func runStateLabel(
        goal: String,
        threshold: Double,
        round: Int,
        onUI: (@Sendable (TurnUIEvent) async -> Void)? = nil
    ) async -> String {
        guard let advisory = await JevBridge.advisory(
            goal: "Agent turn run-state: \(goal)",
            question: JevRunLabel.question,
            options: JevRunLabel.options
        ) else {
            print("JEV_RUN_LABEL skipped=unavailable round=\(round)")
            fflush(stdout)
            return "skipped=unavailable"
        }
        let strength = advisory.probabilities[advisory.choice] ?? 0
        let decision = JevRunLabel.shouldNotice(
            choice: advisory.choice,
            strength: strength,
            floor: threshold
        )
        print("JEV_RUN_LABEL \(decision.label) round=\(round)")
        fflush(stdout)
        if decision.notice, let onUI {
            await onUI(.notice(
                "jev: run looks \(JevBridge.sanitize(advisory.choice)) "
                + "(p=\(String(format: "%.2f", strength))) — consider replanning or stopping"
            ))
        }
        return decision.label
    }

    /// The turn-start route, resolved ONCE by the caller and carried into BOTH
    /// the provider decision and the loop's hint injection. A `nil` `choice`
    /// means disabled/unavailable/below-floor — the loop injects nothing.
    struct RouteResolution: Sendable {
        let choice: String?
    }

    /// The turn's route CHOICE — the capability class jev picked — or nil.
    /// Logs EXACTLY the lines `routeHint` always logged, so `routeHint` now
    /// delegates here and the choice and the hint can never disagree.
    static func routeChoice(
        enabled: Bool,
        goal: String,
        threshold: Double
    ) async -> String? {
        guard JevRoute.shouldRoute(enabled: enabled) else {
            print("JEV_ROUTE skipped=disabled")
            fflush(stdout)
            return nil
        }
        guard let advisory = await JevBridge.advisory(
            goal: "Route the user's request to Pop's best capability: \(goal)",
            question: "route",
            options: JevRoute.options
        ) else {
            print("JEV_ROUTE skipped=unavailable")
            fflush(stdout)
            return nil
        }
        guard JevRoute.hint(from: advisory, floor: threshold) != nil else {
            print("JEV_ROUTE skipped=below-threshold")
            fflush(stdout)
            return nil
        }
        let strength = advisory.probabilities[advisory.choice] ?? 0
        print("JEV_ROUTE choice=\(JevBridge.sanitize(advisory.choice))"
            + " p=\(String(format: "%.2f", strength))")
        fflush(stdout)
        return advisory.choice
    }

    /// ONE skill-routing hint (SPEC §4.4 use (a)), fired at TURN START.
    ///
    /// AWAITS the advisory, bounded by `JevBridge.timeout` (3 s), BEFORE the
    /// first model round. Returns the ADVISORY context line to prepend, or nil.
    /// It logs `JEV_ROUTE` on every path (via `routeChoice`) and NEVER touches
    /// control flow: a nil advisory is `skipped=unavailable`, the messages stay
    /// byte-identical, and the loop proceeds. `enabled == false` is
    /// `skipped=disabled` with NO Keychain read and NO network — the default
    /// path. The hint is the only output; nothing in the loop reads it back.
    static func routeHint(
        enabled: Bool,
        goal: String,
        threshold: Double
    ) async -> String? {
        guard let choice = await routeChoice(
            enabled: enabled,
            goal: goal,
            threshold: threshold
        ) else {
            return nil
        }
        return Self.routeContextLine(choice: choice)
    }

    /// The model-facing routing hint line. Prefixed as ADVISORY ONLY so the
    /// model can weigh it and is free to ignore it — no tool is forced and no
    /// branch keys on it.
    static func routeContextLine(choice: String) -> String {
        "[jev routing hint: \(JevBridge.sanitize(choice)) — advisory only, you may ignore]"
    }

    /// Prepends the ONE hint line to the turn's existing context message — no
    /// new message, so the array shape every provider expects is unchanged.
    /// Prefers the first `.system` message, then the last `.user` message (where
    /// the observation context already rides); an empty or hintless array is
    /// returned untouched.
    static func injectRouteHint(_ hint: String, into messages: [ChatMessage]) -> [ChatMessage] {
        let target = messages.firstIndex { $0.role == .system }
            ?? messages.lastIndex { $0.role == .user }
        guard let target else { return messages }
        var copy = messages
        copy[target].text = "\(hint)\n\(copy[target].text)"
        return copy
    }

    /// Streams one turn, executing tool calls in between.
    ///
    /// `messages` is the already-assembled request (system + tools + context +
    /// recent turns). Tool results are appended to a LOCAL copy, never to the
    /// caller's array: the caller's array is the session history, and a tool
    /// round must not silently become part of what the user sees next turn.
    static func stream(
        provider: ModelProvider,
        messages initialMessages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        route: RouteResolution? = nil,
        onUI: (@Sendable (TurnUIEvent) async -> Void)? = nil,
        maxRounds: Int = AgentLoop.maxRounds,
        onActivity: @escaping @Sendable (ToolRoundOutcome) async -> Void
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var messages = initialMessages
                var round = 0
                // THE TURN'S ROUND BUDGET. Starts at the unplanned floor
                // (`roundBudget(nil)` = 15, or a caller's explicit `maxRounds`),
                // and can only GROW — once the model declares its plan, the
                // remaining rounds are sized from the DECLARED step count.
                // Growth-only on purpose: a turn that already passed the old
                // floor is never retroactively killed. Resets every turn.
                var effectiveBudget = max(maxRounds, Self.roundBudget(planSteps: nil))
                Self.metrics.reset(at: Date())
                // THE INSTANT WORKING INDICATOR. Emitted before the first
                // provider call of the turn, so the panel can say "working…"
                // during the silent first model round — not after the first
                // token, which is 3-6s later.
                if let onUI { await onUI(.working) }
                // Turn-scoped nudge state: at most ONE nudge per turn, and only
                // when the model never planned. A `plan_update` anywhere in the
                // turn — even after tool rounds — cancels the nudge.
                var planUpdateSeen = false
                var nudgeInjected = false
                // The gated-timeout nudge fires at most ONCE per turn, on the
                // first `.timeout` verdict, and resets every turn like the plan
                // nudge.
                var gatedTimeoutNudgeInjected = false
                // JEV RUN-STATE LABELING (SPEC §4.4 use (c)): read the jev config
                // ONCE per turn, not per label, and keep the turn's goal text.
                // Disabled by default; labeling is read-only on the loop.
                let turnConfig = (try? PopConfig.load()) ?? .defaults
                let jevEnabled = turnConfig.jevEnabled
                let jevThreshold = turnConfig.jevThreshold
                let turnGoal = Self.turnGoal(from: initialMessages)
                // JEV SKILL ROUTING (SPEC §4.4 use (a)): at TURN START, before
                // the first model round, ONE advisory line is prepended to the
                // turn's context; on disabled/unavailable/below-floor the messages
                // are byte-identical and the loop is unchanged. When the caller
                // already resolved the route (`route`), that single resolution is
                // REUSED — the advisory is never fired twice — and only the hint
                // line is built here. Otherwise (a direct caller) the loop
                // resolves it itself, exactly as before. The hint is never read
                // back: no tool is forced, no branch keys on it.
                if let route {
                    messages = Self.injectTurnContext(choice: route.choice, into: messages)
                } else if let choice = await Self.routeChoice(
                    enabled: jevEnabled,
                    goal: turnGoal,
                    threshold: jevThreshold
                ) {
                    messages = Self.injectTurnContext(choice: choice, into: messages)
                }
                // MUTATING tool rounds only: a read-only round cannot make a run
                // look stuck, so a reads-only turn never reaches the labeler.
                var mutatingRounds = 0
                do {
                    while true {
                        var text = ""
                        // Did THIS round execute a tool whose result must be fed
                        // back before an answer can exist? Only an OpenAI-shaped
                        // provider sets this: its stream ENDS the moment the model
                        // asks for a tool, so the answer only arrives on the next
                        // stream. A native-tool provider (FoundationModels) runs
                        // the tool inside its own session and answers in the same
                        // stream, so it must NOT be re-streamed.
                        var requestedTool = false
                        Self.metrics.noteProviderCall()
                        for try await event in provider.stream(
                            messages: messages,
                            options: options,
                            tools: tools,
                            // Only for a provider that runs tools itself: for
                            // the others this loop reports each outcome from
                            // `runTool`, and forwarding here would report twice.
                            activity: provider.executesToolsNatively ? onActivity : nil
                        ) {
                            if Task.isCancelled { break }
                            switch event {
                            case .delta(let piece):
                                text += piece
                                continuation.yield(.delta(piece))
                            case .done(let final):
                                text = final
                            case .toolCall(let id, let name, let arguments):
                                continuation.yield(.toolCall(id: id, name: name, arguments: arguments))
                                // The framework already ran it; reporting it
                                // again would execute every tool twice. Its own
                                // execution is gated inside `ToolRegistry.execute`,
                                // so a mutating call is not ungated here.
                                if provider.executesToolsNatively { continue }
                                guard round < effectiveBudget else {
                                    print("TOOL_ROUND_LIMIT reached rounds=\(effectiveBudget)")
                                    fflush(stdout)
                                    // GRACEFUL DEGRADATION: a hard cap that ends
                                    // the turn silently reads to the user as a
                                    // non-answer. Announce the stop ONCE, at the
                                    // trip point (this branch is reached at most
                                    // once per turn by construction), through the
                                    // same transcript-notice path a run-state
                                    // label uses, so the user can act on it
                                    // ("ask me to continue"). The model does NOT
                                    // get a final round here — the loop mechanics
                                    // are unchanged; the notice is the fix.
                                    if let onUI {
                                        await onUI(.notice("Reached my action limit mid-task — ask me to continue."))
                                    }
                                    Self.metrics.report()
                                    if let onUI { await onUI(.ready) }
                                    continuation.yield(.done(text))
                                    continuation.finish()
                                    return
                                }
                                round += 1
                                requestedTool = true
                                if name == "plan_update" { planUpdateSeen = true }
                                // A whole-plan call counts as a plan-exec turn;
                                // its blocked summary (if any) marks the one
                                // adaptation round that may follow.
                                if name == "plan_update", PlanRun.isRun(arguments) {
                                    Self.metrics.notePlanExec()
                                }
                                // The assistant turn that ASKED for the tool must
                                // be on the wire, with a matching id, or an
                                // OpenAI-compatible server treats the result as
                                // an unattached `tool` message and the model
                                // repeats the call instead of answering.
                                let callId = id ?? "call_\(round)"
                                messages.append(ChatMessage(
                                    role: .assistant,
                                    text: text,
                                    toolCalls: [ChatMessage.ToolCall(
                                        id: callId,
                                        name: name,
                                        arguments: arguments.stableString()
                                    )]
                                ))
                                let result = await runTool(
                                    (name, arguments),
                                    onActivity: onActivity
                                )
                                // PLAN-AWARE BUDGET: the model declared or
                                // updated its plan; size the REMAINING rounds
                                // from the DECLARED step count. Growth only —
                                // `max` means a budget already past this value
                                // never shrinks, so a turn that passed the old
                                // floor is not retroactively killed. Logged only
                                // when it actually changes, one line per change.
                                if name == "plan_update",
                                   let declared = Self.declaredPlanSteps(from: result) {
                                    let grown = Self.roundBudget(planSteps: declared)
                                    if grown > effectiveBudget {
                                        effectiveBudget = grown
                                        print("ROUND_BUDGET steps=\(declared) budget=\(grown)")
                                        fflush(stdout)
                                    }
                                }
                                // A VERIFIED ACTION: the executor composed the
                                // receipt itself. Render it and END the turn —
                                // NO model round between the verify step and the
                                // receipt. The model is consulted after an
                                // action task ONLY when a step failed/blocked.
                                if name == "plan_update",
                                   result.hasPrefix("PLAN_EXEC_CONFIRMED") {
                                    let receipt = Self.confirmationLine(result)
                                    Self.metrics.report()
                                    if let onUI { await onUI(.confirmation(receipt)) }
                                    if let onUI { await onUI(.ready) }
                                    continuation.yield(.done(receipt))
                                    continuation.finish()
                                    return
                                }
                                if name == "plan_update", result.hasPrefix("PLAN_EXEC_BLOCKED") {
                                    Self.metrics.notePlanExecFailed()
                                }
                                // A refusal is fed back as a normal tool-role
                                // message, so the model reads "denied" and
                                // moves on instead of retrying a dead end.
                                messages.append(toolMessage(id: callId, name: name, result: result))
                                // THE GATED-TIMEOUT NUDGE: a timeout is silence,
                                // not consent. Inject ONE system message on the
                                // first timeout of the turn, steering the model
                                // off the blocked kind of command. Once per turn.
                                if result.contains(ApprovalGate.timeoutMarker),
                                   !gatedTimeoutNudgeInjected {
                                    messages.append(ChatMessage(
                                        role: .system,
                                        text: Self.gatedTimeoutNudge
                                    ))
                                    gatedTimeoutNudgeInjected = true
                                    print("GATED_TIMEOUT_NUDGE fired")
                                    fflush(stdout)
                                }
                                // JEV RUN-STATE LABELING: count MUTATING rounds
                                // and, on every 6th, ask jev ONE classification
                                // for the run so far. Purely advisory — the
                                // loop's next round is decided by the model, not
                                // by this label.
                                if let executed = ToolRegistry.tool(named: name),
                                   PopTool.requiresApproval(executed.access) {
                                    mutatingRounds += 1
                                    if JevRunLabel.shouldLabel(
                                        enabled: jevEnabled,
                                        mutatingRounds: mutatingRounds
                                    ) {
                                        await Self.runStateLabel(
                                            goal: turnGoal,
                                            threshold: jevThreshold,
                                            round: mutatingRounds,
                                            onUI: onUI
                                        )
                                    }
                                }
                            }
                        }
                        if Task.isCancelled { continuation.finish(); return }
                        // THE PLAN NUDGE: two tool rounds with no `plan_update`
                        // means the request is multi-step but has no visible
                        // plan, so ONE system message is injected for the
                        // remaining rounds. Once per turn, and only when the
                        // model never planned.
                        if requestedTool, !planUpdateSeen, !nudgeInjected,
                           round >= Self.nudgeAfterRounds {
                            messages.append(ChatMessage(role: .system, text: Self.planNudge))
                            nudgeInjected = true
                        }
                        // No tool was executed this round: the round's text IS
                        // the answer. When a tool WAS executed, loop again so
                        // the model reads the result and answers — the existing
                        // `while true` / `maxRounds` machinery depends on this
                        // NOT returning early.
                        if !requestedTool {
                            Self.metrics.report()
                            if let onUI { await onUI(.ready) }
                            continuation.yield(.done(text))
                            continuation.finish()
                            return
                        }
                    }
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}