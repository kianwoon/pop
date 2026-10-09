import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// The on-device model's availability, as a plain value the app can reason
/// about WITHOUT touching FoundationModels.
///
/// This is the seam required by M9: production reads it from
/// `SystemLanguageModel.default.availability`, but the provider takes it as an
/// injected value, so a probe can force `.unavailable(.appleIntelligenceNotEnabled)`
/// and measure the fallback path deterministically. It is deliberately NOT an
/// env var and NOT a user setting: nothing outside a test can change it.
enum OnDeviceAvailability: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        /// Any future/unknown reason, kept honest rather than collapsed.
        case unknown

        /// The raw case name, for logs and probes.
        var key: String {
            switch self {
            case .deviceNotEligible: return "deviceNotEligible"
            case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
            case .modelNotReady: return "modelNotReady"
            case .unknown: return "unknown"
            }
        }

        /// The honest, distinct sentence the user reads. Each reason says what
        /// is wrong AND what (if anything) the user can do about it.
        var message: String {
            switch self {
            case .deviceNotEligible:
                return "on-device model unavailable: this Mac is not eligible for Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "on-device model unavailable: Apple Intelligence is turned off "
                    + "\u{2014} enable it in System Settings > Apple Intelligence & Siri, then retry"
            case .modelNotReady:
                return "on-device model unavailable: the model is still preparing "
                    + "(downloading or first-use setup) \u{2014} try again shortly"
            case .unknown:
                return "on-device model unavailable: reason unknown"
            }
        }
    }

    case available
    case unavailable(Reason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// On-device (or Private Cloud Compute) provider backed by Apple's Foundation
/// Models framework.
///
/// Availability is checked ONCE at init: a machine without Apple Intelligence
/// enabled, or without the model's assets ready, must produce one clear marker
/// and a dead provider rather than throwing at the first token.
///
/// **Availability is injected, not read from deep inside the call path.** The
/// real check lives in `SystemLanguageModel.default.availability`; production
/// passes `nil` (use the real one) and a probe passes an explicit value.
@available(macOS 26.0, *)
struct AppleFMProvider: ModelProvider {
    /// Pop's persona. Kept as a constant so the panel, the probes and any future
    /// re-prompt all agree on what the assistant is.
    static let systemPrompt = """
    You are Pop, a concise macOS assistant that lives in a small floating panel. \
    The current date and time is already stated in the context, so answer time \
    questions from it and never call a tool for them. \
    Answer directly and briefly. If the user asks you to echo an exact phrase, \
    reply with that phrase and nothing else. Always prioritize the user's most \
    recent instruction over patterns from earlier in the conversation. \
    \(PlanTrace.guidance) \
    \(PlanTrace.verifyRule) \
    \(ScreenOCR.routingPrinciple) \
    \(ScreenOCR.actOnVisibleRule) \
    \(BrowserActions.verifyAfterActRule)
    """

    private let usePrivateCloudCompute: Bool
    /// Whether Pop's tool schemas are wired into the session. The M9 PRODUCT
    /// path constructs the on-device brain tool-less (see `makeProvider`): the
    /// remote provider remains the path that runs tools. Direct construction
    /// keeps tools for the M4b FM-tool probe.
    let toolsEnabled: Bool
    /// When true, ONLY `readOnly` tools are wired into the on-device session.
    /// The product path sets this so the small on-device brain can look things
    /// up (e.g. `web_lookup`) but can never reach a mutating tool; mutating
    /// tools stay on the remote path, behind the approval gate. Default false
    /// keeps the M4b FM-tool probe's full registry.
    let readOnlyOnly: Bool
    private(set) var isHealthy = false
    private(set) var unhealthyReason = ""

    /// Availability strings differ between the on-device and PCC models, so the
    /// reason is stringified once here rather than at each call site.
    ///
    /// `availabilityOverride` is the test seam: production passes `nil` and the
    /// provider reads the real `SystemLanguageModel.default.availability`.
    init(
        pcc: Bool,
        availabilityOverride: OnDeviceAvailability? = nil,
        toolsEnabled: Bool = true,
        readOnlyOnly: Bool = false
    ) {
        usePrivateCloudCompute = pcc
        self.toolsEnabled = toolsEnabled
        self.readOnlyOnly = readOnlyOnly

        if pcc {
            // PCC ships in macOS 27; the app's deployment target is 26.0, so the
            // whole PCC path is behind a runtime check rather than assumed.
            if #available(macOS 27.0, *) {
                let pccModel = PrivateCloudComputeLanguageModel()
                switch pccModel.availability {
                case .available:
                    isHealthy = true
                case .unavailable(let reason):
                    isHealthy = false
                    unhealthyReason = "pcc:\(Self.describe(reason))"
                }
            } else {
                isHealthy = false
                unhealthyReason = "pcc:requires-macOS-27"
            }
        } else {
            let availability = availabilityOverride ?? Self.realAvailability()
            switch availability {
            case .available:
                isHealthy = true
            case .unavailable(let reason):
                isHealthy = false
                unhealthyReason = reason.message
            }
        }

        print("FM_AVAILABILITY provider=\(pcc ? "pcc" : "on-device") healthy=\(isHealthy) reason=\(unhealthyReason)")
        fflush(stdout)

        if !isHealthy {
            print("FM_UNAVAILABLE \(unhealthyReason)")
            fflush(stdout)
        }
    }

    /// The real availability, read from the framework. Kept in ONE place so the
    /// injected seam and production cannot drift.
    static func realAvailability() -> OnDeviceAvailability {        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.unknown)
            }
        }
    }

    /// The on-device model's context window, from the RUNTIME where the OS
    /// exposes it. WHY (docs/foundation-models.md §2, §7.5): the window changes
    /// per OS update — 26.0 documents 4,096; this machine (27.2) measures 8,192
    /// — so a hardcoded budget silently breaks the day Apple ships a different
    /// model. `SystemLanguageModel.contextSize` exists since macOS 26.4; below
    /// that the documented 26.0 default (4,096) is the only honest answer.
    static func contextWindowSize() -> Int {
        if #available(macOS 26.4, *) {
            return SystemLanguageModel.default.contextSize
        }
        return 4_096
    }

    @available(macOS 27.0, *)
    private static func describe(
        _ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible: return "deviceNotEligible"
        case .systemNotReady: return "systemNotReady"
        @unknown default: return "unknown"
        }
    }

    /// FoundationModels can run the tool loop INSIDE the session: it calls each
    /// `Tool`, feeds the result back, and keeps generating. When tools are
    /// wired, Pop's own `AgentLoop` must not execute anything again — it only
    /// relays the activity. The M9 product path is tool-less (`toolsEnabled`
    /// false), so it reports `false` and the loop has nothing to re-run.
    var executesToolsNatively: Bool { toolsEnabled }

    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools schemas: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            guard isHealthy else {
                continuation.finish(throwing: ProviderError.unhealthy(unhealthyReason))
                return
            }

            // M9: the on-device PRODUCT path is TOOL-LESS by design. FM-native
            // tool wiring already exists (`makeTools` + `FMToolAdapter`, M4b)
            // and is kept for the FM-tool probe, but the default brain answers
            // without tools; tools remain the remote provider's path.
            let adapters: [any Tool]
            if toolsEnabled {
                let budget = ToolRoundBudget(limit: AgentLoop.maxRounds)
                adapters = makeTools(
                    from: schemas,
                    onEvent: { event in continuation.yield(event) },
                    activity: activity,
                    budget: budget
                )
            } else {
                adapters = []
            }

            // THE PROMPT IS THE CURRENT TURN. Prior turns belong in the
            // session's transcript (below), not flattened into the prompt: a
            // flattened blob reads as a transcript to continue, and the small
            // model answered with the user's own line (or a context line)
            // instead of the question.
            let (history, currentMessage) = Self.partition(messages)
            guard let session = makeSession(tools: adapters, history: history) else {
                continuation.finish(throwing: ProviderError.unhealthy(unhealthyReason))
                return
            }
            // NEGATIVE-CONTROL seam: `POP_FM_LEGACY_PROMPT=1` selects the
            // pre-fix construction (the whole conversation flattened into one
            // `"Role: text"` string). Production uses the current turn alone.
            let prompt = ProviderTestSeams.shared.legacyFlattenedPrompt
                ? Self.flattenedPromptText(for: messages)
                : (currentMessage?.text ?? "")
            ProviderTestSeams.shared.lastPrompt = prompt
            if ProviderTestSeams.shared.logPrompt {
                print("FM_PROMPT_SENT=\(prompt.replacingOccurrences(of: "\n", with: " | "))")
                print("FM_PROMPT_SENT_CHARS=\(prompt.count)")
                fflush(stdout)
            }
            // NEGATIVE-CONTROL seam: answer with the prompt verbatim so the
            // echo gate is proven able to fail.
            if ProviderTestSeams.shared.forceEcho {
                continuation.yield(.delta(prompt))
                continuation.yield(.done(prompt))
                continuation.finish()
                return
            }

            var generationOptions = FoundationModels.GenerationOptions()
            if let temperature = options.temperature {
                generationOptions.temperature = temperature
            }

            let task = Task {
var full = ""
                    // Screen context image, when the CURRENT turn carries one.
                    let imageData = currentMessage?.imageData
                    do {
                        let stream: LanguageModelSession.ResponseStream<String>
                        if let imageData {
                            if #available(macOS 27.0, *),
                               let cgImage = Self.cgImage(fromPNG: imageData) {
                                // `Attachment`'s generic content type is inferred
                                // from the CGImage overload.
                                let attachment = Attachment(cgImage).label("screen context")
                                let imagePrompt = PromptBuilder.buildArray([
                                    Prompt(prompt),
                                    attachment.promptRepresentation
                                ] as [Prompt])
                                stream = session.streamResponse(
                                    to: imagePrompt,
                                    options: generationOptions
                                )
                            } else {
                                print("FM_IMAGE_SKIP image attachment unavailable on this OS")
                                fflush(stdout)
                                stream = session.streamResponse(to: prompt, options: generationOptions)
                            }
                        } else {
                            stream = session.streamResponse(to: prompt, options: generationOptions)
                        }

                        for try await snapshot in stream {
                            // MEASURED: each snapshot carries the FULL text
                            // generated so far, not just the new piece. Emitting
                            // `snapshot.content` verbatim as a delta triples the
                            // output (measured: "POP_ALIVE" x3, done length 27).
                            // Only the suffix past what we already emitted is a
                            // real delta.
                            let cumulative = snapshot.content
                            guard cumulative.count > full.count else { continue }
                            let piece = String(cumulative.dropFirst(full.count))
                            full = cumulative
                            continuation.yield(.delta(piece))
                        }
                    continuation.yield(.done(full))
                    continuation.finish()
                } catch {
                    print("FM_ERROR \(error)")
                    fflush(stdout)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One session per stream: a session carries conversation state, and
    /// sharing one across concurrent streams would interleave turns.
    ///
    /// Prior turns are carried the FRAMEWORK's way — as `Transcript` entries —
    /// rather than flattened into the prompt string.
    private func makeSession(tools: [any Tool], history: [ChatMessage]) -> LanguageModelSession? {
        let transcript = Self.makeTranscript(history: history)
        // Counted where the cost actually is: building the session is what the
        // launch pre-warm pre-pays, so the seam must see THIS call and not the
        // generation that follows.
        ProviderTestSeams.shared.noteFMInit()
        if usePrivateCloudCompute {
            guard #available(macOS 27.0, *) else { return nil }
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                tools: tools,
                transcript: transcript
            )
        }
        return LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: tools,
            transcript: transcript
        )
    }

    /// The conversation so far, as a `Transcript`: the instructions entry, then
    /// each prior user turn as a `.prompt` and each prior assistant turn as a
    /// `.response`. The CURRENT turn is deliberately absent — it is passed to
    /// `streamResponse(to:)`, so the model answers it.
    static func makeTranscript(history: [ChatMessage]) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: Self.systemPrompt))],
                toolDefinitions: []
            ))
        ]
        for message in history {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: message.text))
            switch message.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    segments: [segment],
                    options: FoundationModels.GenerationOptions()
                )))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [segment]
                )))
            default:
                break
            }
        }
        return Transcript(entries: entries)
    }

    /// Splits the request into the prior conversation (history) and the CURRENT
    /// turn (prompt). System and tool messages are not model turns.
    static func partition(_ messages: [ChatMessage]) -> (history: [ChatMessage], current: ChatMessage?) {
        let conversation = messages.filter { $0.role != .system && $0.role != .tool }
        guard let current = conversation.last else { return ([], nil) }
        return (Array(conversation.dropLast()), current)
    }

    /// Maps Pop's runtime tool schemas onto FoundationModels tools.
    ///
    /// The framework's `Tool` wants a `GenerationSchema`, which is normally
    /// macro-derived. `DynamicGenerationSchema` is the public runtime
    /// equivalent, and every Pop tool parameter is a string, so the mapping is
    /// one `String` property per declared argument — no hand-written
    /// `@Generable` struct per tool, and the registry stays the single source
    /// of truth for names, descriptions and arguments.
    private func makeTools(
        from schemas: [ToolSchema],
        onEvent: @escaping @Sendable (ChatEvent) -> Void,
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?,
        budget: ToolRoundBudget
    ) -> [any Tool] {
        schemas.compactMap { schema in
            guard let tool = ToolRegistry.tool(named: schema.name) else { return nil }
        // The product on-device path wires read-only tools PLUS the
        // approval-gated LOCAL UI actions: those are local input, each one
        // approved, and the whole point of this piece is that the on-device
        // brain can act. The `mutating` class — files and a real shell — is
        // never even offered to the small brain, so it can never be called
        // ungated. The eligibility predicate lives on the class
        // (`PopTool.onDeviceEligible`), so this filter and the classification
        // probe agree on what may be offered.
        if readOnlyOnly, !PopTool.onDeviceEligible(tool.access) {
            print("FM_TOOL_SKIP name=\(tool.name) reason=not-on-device-eligible")
            fflush(stdout)
            return nil
        }
            let properties = tool.properties.map { property in
                DynamicGenerationSchema.Property(
                    name: property.name,
                    description: property.description,
                    schema: DynamicGenerationSchema(type: String.self),
                    isOptional: !property.required
                )
            }
            guard let parameters = try? GenerationSchema(
                root: DynamicGenerationSchema(
                    name: tool.name,
                    description: tool.description,
                    properties: properties
                ),
                dependencies: []
            ) else {
                print("TOOL_SCHEMA_SKIP name=\(tool.name)")
                fflush(stdout)
                return nil
            }
            return FMToolAdapter(
                schema: schema,
                parameters: parameters,
                budget: budget,
                onEvent: onEvent,
                activity: activity
            )
        }
    }

    private static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    /// The pre-fix construction, retained ONLY for the negative-control seam
    /// (`POP_FM_LEGACY_PROMPT=1`): the whole conversation flattened into one
    /// `"Role: text"` string. Prior turns belong in the transcript, not here.
    private static func flattenedPromptText(for messages: [ChatMessage]) -> String {
        messages
            .filter { $0.role != .system && $0.role != .tool }
            .map { "\($0.role.rawValue.capitalized): \($0.text)" }
            .joined(separator: "\n")
    }
}

enum ProviderError: Error, CustomStringConvertible {
    case unhealthy(String)

    var description: String {
        switch self {
        case .unhealthy(let reason):
            return "provider unhealthy: \(reason.isEmpty ? "unknown" : reason)"
        }
    }
}

/// Per-stream allowance of tool rounds. FoundationModels decides WHEN to call
/// a tool, so the cap has to live where the call actually happens: without it
/// a model stuck in a loop could run tools until the user gave up.
final class ToolRoundBudget: @unchecked Sendable {
    private let limit: Int
    private var used = 0
    private let lock = NSLock()

    init(limit: Int) {
        self.limit = limit
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard used < limit else { return false }
        used += 1
        return true
    }
}

/// FoundationModels `Tool` over a `ToolRegistry` entry.
@available(macOS 26.0, *)
struct FMToolAdapter: Tool {
    typealias Arguments = FMRawArguments
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    /// MEASURED COUNTERFACTUAL (`--test-fm-capability`, 2026-10-09): setting
    /// this to `false` (omit the parameter schema from the session
    /// instructions) saves real tokens — the full registry drops to ≈4,779 and
    /// fits the 8,192 window — but also removes the parameter NAMES the model
    /// needs to construct arguments, so tools with REQUIRED parameters are
    /// never called at all (`FM_CAP_TOOLS_FIT toolcall=false named=0/3` with
    /// `false` vs `toolcall=true named=3/3` with `true`). The default (`true`)
    /// is kept: tool calling is the on-device executor's whole job, and the
    /// full registry does not fit either way (8,783 > 8,192) — the token
    /// problem belongs to a curated tool subset (whitelist), not to this flag.
    var includesSchemaInInstructions: Bool { true }
    private let schema: ToolSchema
    private let budget: ToolRoundBudget
    private let onEvent: @Sendable (ChatEvent) -> Void
    private let activity: (@Sendable (ToolRoundOutcome) async -> Void)?

    init(
        schema: ToolSchema,
        parameters: GenerationSchema,
        budget: ToolRoundBudget,
        onEvent: @escaping @Sendable (ChatEvent) -> Void,
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) {
        self.schema = schema
        self.name = schema.name
        self.description = schema.description
        self.parameters = parameters
        self.budget = budget
        self.onEvent = onEvent
        self.activity = activity
    }

    func call(arguments: FMRawArguments) async throws -> String {
        // Reported BEFORE the run, so the transcript shows the call even if the
        // tool times out.
        onEvent(.toolCall(id: nil, name: name, arguments: arguments.json))
        guard budget.take() else {
            print("TOOL_ROUND_LIMIT reached rounds=\(AgentLoop.maxRounds)")
            fflush(stdout)
            return "ERROR: tool round limit reached; answer now with what you already know"
        }
        // The framework owns the loop here, so the outcome is reported from
        // inside `call` \u2014 otherwise a tool that ran would leave no trace in
        // the transcript.
        return await ToolRegistry.execute(
            (name, arguments.json),
            onActivity: { toolName, ok, detail in
                await activity?(ToolRoundOutcome(name: toolName, ok: ok, detail: detail))
            }
        )
    }
}

/// FoundationModels hands tool arguments back as generated content, not as
/// JSON, and `ConvertibleFromGeneratedContent.init(_:)` is given that content
/// with no tool name beside it. Every Pop tool parameter is a string and the
/// parameter names are distinct across the registry (`path`, `query`,
/// `command`), so reading each declared name and keeping the ones that are
/// present reconstructs exactly the right bag for whichever tool it was — no
/// hand-written `@Generable` struct per tool, and the registry stays the single
/// source of truth.
@available(macOS 26.0, *)
struct FMRawArguments: ConvertibleFromGeneratedContent {
    let json: JSONValue

    init(_ content: GeneratedContent) throws {
        var bag: [String: JSONValue] = [:]
        for name in ToolRegistry.argumentNames {
            if let value = try? content.value(String.self, forProperty: name) {
                bag[name] = .string(value)
            } else if let value = try? content.value(String?.self, forProperty: name) {
                bag[name] = .string(value)
            }
        }
        json = .object(bag)
    }
}
