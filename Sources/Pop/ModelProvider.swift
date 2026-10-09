import Foundation

/// One turn in a conversation. `imageRef` is a placeholder only — image input
/// arrives in M3; nothing reads it yet.
struct ChatMessage: Sendable, Equatable {
    enum Role: String, Sendable, Equatable, Codable {
        case system
        case user
        case assistant
        /// A tool RESULT fed back to the model after it asked for one. Never
        /// authored by the user, so it is excluded from the transcript the user
        /// reads and from the session file.
        case tool
    }

    /// One tool request an assistant turn made, kept so the OpenAI-shaped wire
    /// format can echo the assistant `tool_calls` entry that a following `.tool`
    /// result answers. OpenAI-compatible servers reject (or silently mis-read) a
    /// `tool` message that no assistant `tool_calls` entry introduced with a
    /// matching id — the model then repeats the call forever instead of
    /// answering.
    struct ToolCall: Sendable, Equatable {
        var id: String
        var name: String
        /// Raw JSON arguments string, exactly as sent to the model.
        var arguments: String
    }

    let role: Role
    var text: String

    /// Future multimodal attachment handle.
    var imageRef: String?

    /// Encoded image (PNG) attached to this turn, for M3 screen context. Text-only
    /// providers ignore it. Kept as raw data rather than a URL so a screenshot
    /// never has to hit the filesystem to reach the model.
    var imageData: Data?

    /// Set on a `.tool` result: the id of the assistant tool call it answers.
    var toolCallId: String?

    /// Set on an `.assistant` turn that requested tools. `nil`/empty for a plain
    /// assistant answer, so a normal turn renders exactly as before.
    var toolCalls: [ToolCall]?

    init(
        role: Role,
        text: String,
        imageRef: String? = nil,
        imageData: Data? = nil,
        toolCallId: String? = nil,
        toolCalls: [ToolCall]? = nil
    ) {
        self.role = role
        self.text = text
        self.imageRef = imageRef
        self.imageData = imageData
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }
}

/// Per-request knobs. Mirrors FoundationModels' `GenerationOptions` and the
/// OpenAI-shaped `temperature`, so a provider can map one struct onto either.
struct GenerationOptions: Sendable, Equatable {
    var temperature: Double?
    var maxTokens: Int?

    init(temperature: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// Streaming unit of a completion.
enum ChatEvent: Sendable, Equatable {
    case delta(String)
    case done(String)
    /// The model asked for a tool. `arguments` is the raw JSON object the model
    /// produced; a provider that executes tools itself re-emits this purely as
    /// an activity marker. `id` is the provider's tool-call id where it has one
    /// (OpenAI-shaped SSE carries one); `nil` for a native-tool marker.
    case toolCall(id: String?, name: String, arguments: JSONValue)
}

/// The one seam every backend implements. Providers are constructed once and
/// may be asked for several streams; they must not assume one stream per call.
protocol ModelProvider: Sendable {
    /// Cheap readiness check performed at init so an unavailable backend is
    /// reported once, loudly, instead of failing mid-stream.
    var isHealthy: Bool { get }

    /// Human-readable reason the provider is unhealthy (empty when healthy).
    var unhealthyReason: String { get }

    /// `tools` is the fixed, alphabetically-sorted schema array. It is a
    /// parameter rather than provider state so the bytes on the wire cannot
    /// drift between two turns of the same conversation.
    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error>

    /// True when the framework itself runs the tool loop (FoundationModels
    /// executes tools inside `LanguageModelSession`), so `AgentLoop` must NOT
    /// also re-run them from the emitted events.
    var executesToolsNatively: Bool { get }
}

extension ModelProvider {
    var executesToolsNatively: Bool { false }
}

extension ModelProvider {
    /// Flattens a provider's event stream into the final assistant text.
    /// Shared by the probes so provider-specific tail handling lives in one place.
    func collectText(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema] = []
    ) async throws -> (full: String, events: [ChatEvent]) {
        var events: [ChatEvent] = []
        var full = ""
        for try await event in stream(
            messages: messages,
            options: options,
            tools: tools,
            activity: nil
        ) {
            events.append(event)
            switch event {
            case .delta(let piece):
                full += piece
            case .done(let text):
                full = text
            case .toolCall:
                break
            }
        }
        return (full, events)
    }
}