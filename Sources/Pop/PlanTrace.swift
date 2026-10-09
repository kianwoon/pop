import Foundation

/// The VISIBLE PLAN LAYER: what Pop is doing, as steps the user watches.
///
/// The measured defect this exists for: a multi-step request ("find what Jing
/// Tong messaged me") was answered in ONE tool round with no decomposition, no
/// progress, and no check that the work actually finished — so Pop could answer
/// confidently over steps it never took.
///
/// The shape is deliberately generic. A step is whatever the MODEL wrote: no
/// task names, no domains, no per-use-case branching. `apply` only ever
/// records what it is told and re-renders; it never decides what the plan
/// should contain.
///
/// THREE PROPERTIES, all load-bearing:
///  * ONE CURRENT PLAN. `apply` REPLACES the plan. Appending would scroll a
///    fresh block of lines past the user on every status change, so the last
///    state wins and the block is rendered in place.
///  * HONEST PARSING. The payload is small structured text, parsed leniently
///    (`steps: a | b | c`, `status: 1 done, 2 running`, `ready: true`). An
///    index that names no step, or a status word that is not one of the four,
///    is refused as text — never applied, never a crash.
///  * THE VERIFY RULE is stated ONCE, here, and travels with the guidance that
///    tells the model when to plan at all (`guidance`).
struct PlanTrace {
    /// Where a step stands. Four states, no others: a step the model invented a
    /// fifth state for is refused rather than silently coerced.
    enum Status: String, Sendable, Equatable, CaseIterable {
        case pending
        case running
        case done
        case blocked

        /// The compact marker the user reads. ASCII on purpose: this renders in
        /// a small monospace line, and a glyph that fails to encode would show
        /// as a replacement box in the one place the user is watching progress.
        var marker: String {
            switch self {
            case .pending: return "[ ]"
            case .running: return "[~]"
            case .done: return "[x]"
            case .blocked: return "[!]"
            }
        }
    }

    struct Step: Sendable, Equatable {
        var text: String
        var status: Status = .pending
        /// One line of the model's own explanation, for `running`/`blocked`.
        var note: String = ""
    }

    /// The single plan block Pop renders. Keyed so a future second block (a
    /// sub-plan, say) cannot silently overwrite this one.
    static let blockID = "current"

    /// Refuses a malformed update with a reason the model can read and fix.
    struct ParseError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    // MARK: - The rules, stated once

    /// WHEN to plan, and what a plan obliges the model to do before it answers.
    /// Appended to Pop's system guidance, so it reaches BOTH transports (the
    /// on-device session and the OpenAI-shaped system message) from one string.
    static let guidance = """
        PLANNING: for a multi-step request — anything that needs two or more \
        tool rounds, or that the user asked you to do more than one thing — \
        emit the WHOLE plan as ONE `plan_update` call with a `run` payload: a \
        JSON array whose elements are {"label": "...", "tool": "...", \
        "arguments": { ... }}, in the order they must run. Pop then executes \
        every step in order without consulting you between them and shows the \
        plan live, so `run` must contain the real tools and their complete \
        arguments. After the steps run you are asked ONCE to compose the answer \
        from their results; if a step fails the run stops and you are asked \
        ONCE to explain the blocked step, and you must never re-run the whole \
        plan. Use `plan_update` with `steps`/`status`/`ready` (and no `run`) \
        only to update a plan without executing it. For a simple one-shot \
        question answer directly and make no plan.
        """

    /// THE VERIFY-BEFORE-ANSWER RULE. One generic rule, no per-site or
    /// per-task logic: an unfinished step means the answer SAYS so. A confident
    /// answer laid over a blocked or pending step is the failure this exists to
    /// prevent.
    static let verifyRule = """
        BEFORE ANSWERING a planned request, check your own plan: if any step is \
        still `blocked` or unfinished, the answer must say what is done, what is \
        blocked or missing, and why — never a confident answer over unfinished \
        steps.
        """

    // MARK: - State

    /// The rendered blocks, keyed by `blockID`. ONE entry by construction:
    /// `apply` writes the same key every time, which is what makes an update a
    /// REPLACEMENT rather than an append.
    private(set) var blocks: [String: [Step]] = [:]
    private(set) var ready = false

    /// The plan's step list, empty when no plan exists.
    var steps: [Step] { blocks[Self.blockID] ?? [] }

    /// The lines the transcript shows: one compact line per step, live status.
    var renderedLines: [String] {
        steps.enumerated().map { index, step in
            var line = "\(index + 1). \(step.status.marker) \(step.text)"
            if !step.note.isEmpty { line += " — \(step.note)" }
            return line
        }
    }

    /// A model-facing echo of the accepted update, so the next round reads what
    /// the plan now says rather than what it intended to say.
    var summary: String {
        guard !steps.isEmpty else { return "no plan recorded." }
        let counts = Status.allCases
            .map { status in
                let n = steps.filter { $0.status == status }.count
                return n == 0 ? nil : "\(n) \(status.rawValue)"
            }
            .compactMap { $0 }
            .joined(separator: ", ")
        return "plan recorded: \(steps.count) step(s) [\(counts)]"
            + (ready ? "; answer declared ready." : ".")
    }

    /// Starts a turn clean: a plan belongs to the request that made it.
    mutating func reset() {
        blocks.removeAll()
        ready = false
    }

    /// Applies one `plan_update`. Every argument is OPTIONAL, because the model
    /// sets the list once and then only moves statuses; an empty call changes
    /// nothing and says so.
    ///
    /// Lenient parsing, strict meaning: separators may be `|`, `,` or newlines
    /// for the step list, and a status entry may be `2 running`, `2 running:
    /// note` or `2 running — note`. An index with no such step, or a status word
    /// outside the four, is an error.
    mutating func apply(
        stepsText: String?,
        statusText: String?,
        readyText: String?
    ) throws {
        let rawSteps = stepsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawStatus = statusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawReady = readyText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !rawSteps.isEmpty || !rawStatus.isEmpty || !rawReady.isEmpty else {
            throw ParseError(message: """
                nothing to update: pass `steps` (a `|`-separated list), \
                `status` (e.g. "1 done, 2 running"), or `ready` (true/false).
                """)
        }

        var plan = steps
        if !rawSteps.isEmpty {
            plan = rawSteps
                .components(separatedBy: CharacterSet(charactersIn: "|,\n"))
                .map { Step(text: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.text.isEmpty }
            guard !plan.isEmpty else {
                throw ParseError(message: "`steps` held no actual step text.")
            }
        }

        if !rawStatus.isEmpty {
            for entry in rawStatus.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                // `2 running: note` — the LEADING integer is the 1-based step
                // number, everything after it is the status and its note.
                let tokens = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
                guard tokens.count == 2, let number = Int(tokens[0]) else {
                    throw ParseError(message: """
                        could not read "\(trimmed)" in `status`: each entry must \
                        be the step number then the status, e.g. "1 done".
                        """)
                }
                let rest = tokens[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rest.isEmpty else {
                    throw ParseError(message: """
                        could not read "\(trimmed)" in `status`: each entry must \
                        start with the step number, e.g. "1 done".
                        """)
                }
                guard number >= 1, number <= plan.count else {
                    throw ParseError(message: """
                        step \(number) does not exist (the plan has \
                        \(plan.count) step(s)).
                        """)
                }
                let (word, note) = Self.splitStatus(rest)
                guard let status = Status(rawValue: word) else {
                    throw ParseError(message: """
                        "\(word)" is not a step status. Use one of: \
                        \(Status.allCases.map(\.rawValue).joined(separator: ", ")).
                        """)
                }
                plan[number - 1].status = status
                plan[number - 1].note = note
            }
        }

        if !rawReady.isEmpty {
            switch rawReady.lowercased() {
            case "true", "yes", "1", "ready":
                ready = true
            case "false", "no", "0":
                ready = false
            default:
                throw ParseError(message: "`ready` must be true or false, got \"\(rawReady)\".")
            }
        }

        blocks[Self.blockID] = plan
        print("PLAN_UPDATED steps=\(plan.count) ready=\(ready)")
        fflush(stdout)
    }

    /// `running: reading the windows` → `("running", "reading the windows")`.
    /// An unknown word is NOT coerced here; `apply` refuses it.
    private static func splitStatus(_ rest: String) -> (String, String) {
        let separators = CharacterSet(charactersIn: ":—–-\n")
        guard let range = rest.rangeOfCharacter(from: separators) else {
            return (rest.lowercased(), "")
        }
        let word = String(rest[rest.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let note = String(rest[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (word.lowercased(), note)
    }
}

/// WHOLE-PLAN EXECUTION. The model emits ONE structured `plan_update` whose
/// `run` argument carries every step with its complete arguments; the executor
/// then runs them in order with NO model round in between. This is jev's
/// philosophy ported into Pop's loop: one typed decision, executed
/// deterministically. The step text and domains are whatever the MODEL wrote —
/// there is no per-use-case branching here.
enum PlanRun {
    struct Step: Sendable, Equatable {
        /// The line the user watches.
        var label: String
        var tool: String
        var arguments: JSONValue
        /// THE CHECKPOINT FLAG. `see: true` means "I must SEE this step's RESULT
        /// before the remaining steps make sense": the executor stops the batched
        /// run after this step and hands the accumulated evidence back to the
        /// model through the ordinary post-run path. WHY it exists: every model
        /// round costs ≈ 11-13 s against the user's endpoint, so unmarked steps
        /// run on the executor's mechanical verification alone — only a step
        /// whose result genuinely gates the rest buys a consult. Absent/false → false.
        var see: Bool = false
    }

    struct ParseError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    /// TRUE when a `plan_update` argument bag carries a runnable step list.
    static func isRun(_ arguments: JSONValue) -> Bool {
        guard let raw = arguments.objectValue["run"].flatMap(ToolRegistry.stringValue) else {
            return false
        }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parses the `run` payload: a JSON array of
    /// `{"label": "...", "tool": "...", "arguments": { ... }}` objects. Lenient
    /// about `label` (it falls back to the tool and its arguments) and strict
    /// about `tool`; a step that names `plan_update` is refused so the executor
    /// can never recurse into itself.
    static func parse(_ raw: String) throws -> [Step] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError(message: "`run` was empty")
        }
        guard let data = trimmed.data(using: .utf8),
              let value = try? JSONValue.decode(data) else {
            throw ParseError(message: """
                `run` was not valid JSON; pass a JSON array of \
                {"tool": "...", "arguments": { ... }} steps.
                """)
        }
        guard case .array(let items) = value else {
            throw ParseError(message: "`run` must be a JSON array of steps.")
        }
        guard !items.isEmpty else {
            throw ParseError(message: "`run` held no steps.")
        }
        var steps: [Step] = []
        for (index, item) in items.enumerated() {
            guard case .object(let object) = item,
                  let tool = object["tool"].flatMap(ToolRegistry.stringValue),
                  !tool.isEmpty
            else {
                throw ParseError(message: """
                    step \(index + 1) must be an object with a "tool" name.
                    """)
            }
            guard tool != "plan_update" else {
                throw ParseError(message: """
                    step \(index + 1) may not call plan_update: a plan cannot \
                    contain a plan.
                    """)
            }
            let arguments = object["arguments"] ?? .object([:])
            let label = object["label"].flatMap(ToolRegistry.stringValue)
                ?? "\(tool) \(arguments.stableString())"
            let see = parseSeeFlag(object["see"])
            steps.append(Step(label: label, tool: tool, arguments: arguments, see: see))
        }
        return steps
    }

    /// Lenient `"see"` read: absent/false → false. Accepts a JSON bool, the
    /// strings "true"/"1" (case-insensitive), or the number 1. Any other value
    /// is false, NEVER an error — the flag is an optimization, not a
    /// correctness gate, so a malformed one must not refuse an otherwise valid
    /// plan.
    static func parseSeeFlag(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .bool(let flag):
            return flag
        case .number(let number):
            return number == 1
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed == "true" || trimmed == "1"
        case .object, .array, .null:
            return false
        }
    }

    /// THE EXECUTOR-COMPOSED RECEIPT for a VERIFIED SEND.
    ///
    /// Generic by construction — no task, site or app name is known here:
    ///  * the plan's LAST step re-reads the screen (the verify the shipped
    ///    guidance demands after any mutating action), and
    ///  * an earlier step TYPED text ending in Return (the documented send
    ///    shape: "a newline in `text` sends the message").
    /// The receipt is built from what the executor ACTUALLY ran: the typed
    /// text, and the recipient AS READ FROM THE SCREEN (the verify read's
    /// window title). It lets the caller render the confirmation with no model
    /// round between the verify step and the receipt.
    static func verifiedSendConfirmation(steps: [Step], results: [String]) -> String? {
        guard !steps.isEmpty, steps.count == results.count else { return nil }
        guard steps.last?.tool == "screen_read" else { return nil }
        guard let sendIndex = steps.lastIndex(where: { step in
            guard step.tool == "ui_type" else { return false }
            let text = step.arguments.objectValue["text"].flatMap(ToolRegistry.stringValue) ?? ""
            return text.contains("\n")
        }) else { return nil }
        let raw = steps[sendIndex].arguments.objectValue["text"]
            .flatMap(ToolRegistry.stringValue) ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let recipient = recipientFromScreen(results[results.count - 1])
        return recipient.isEmpty
            ? "✓ Sent \"\(text)\""
            : "✓ Sent \"\(text)\" to \(recipient)"
    }

    /// The recipient AS READ FROM THE SCREEN: the verify read's window title,
    /// which is where a conversation names the person it is with. Returns ""
    /// when the reading named no window, so the receipt never invents one.
    private static func recipientFromScreen(_ modelFacing: String) -> String {
        let prefix = "Window title: "
        for rawLine in modelFacing.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            let title = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            if title.isEmpty || title == "(untitled)" { return "" }
            return title
        }
        return ""
    }
}

/// The live plan, shared by the tool that writes it and the UI that renders it.
///
/// `Sendable` through a lock for the same reason `ProviderTestSeams` is: the
/// tool runs on the loop's task and the UI reads on the main actor.
final class PlanTraceStore: @unchecked Sendable {
    static let shared = PlanTraceStore()

    private let lock = NSLock()
    private var trace = PlanTrace()

    /// Applies an update. Throws `PlanTrace.ParseError`, which the tool turns
    /// into text for the model.
    func apply(
        stepsText: String?,
        statusText: String?,
        readyText: String?
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        try trace.apply(stepsText: stepsText, statusText: statusText, readyText: readyText)
        return trace.summary
    }

    /// Replaces the step list with the whole-plan executor's ordered labels.
    func setSteps(_ labels: [String]) {
        lock.lock()
        defer { lock.unlock() }
        _ = try? trace.apply(
            stepsText: labels.joined(separator: " | "),
            statusText: nil,
            readyText: nil
        )
    }

    /// Moves one 1-based step's status as the executor advances. Best-effort:
    /// a mark that cannot apply must never take the step's execution down.
    func mark(_ index: Int, status: PlanTrace.Status, note: String = "") {
        lock.lock()
        defer { lock.unlock() }
        let entry = note.isEmpty
            ? "\(index) \(status.rawValue)"
            : "\(index) \(status.rawValue): \(note)"
        _ = try? trace.apply(stepsText: nil, statusText: entry, readyText: nil)
    }

    var renderedLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return trace.renderedLines
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return trace.ready
    }

    /// A turn-scoped clear, so one request's plan never haunts the next.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        trace.reset()
    }
}