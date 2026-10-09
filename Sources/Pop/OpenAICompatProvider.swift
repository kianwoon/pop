import Foundation

/// Any OpenAI-shaped `POST {base}/chat/completions` endpoint: llama.cpp,
/// Ollama's compat route, LM Studio, vLLM, OpenAI itself.
///
/// Streaming is SSE: `data:` lines carrying one JSON object each, terminated by
/// the literal `data: [DONE]` sentinel.
struct OpenAICompatProvider: ModelProvider {
    struct Configuration: Sendable {
        var baseURL: String
        var model: String
        var apiKey: String
        var temperature: Double?
        /// Config-driven cloud thinking policy, threaded exactly like
        /// `temperature`: it is set from `PopConfig` at construction time and
        /// never read from a global at request time. See
        /// `PopConfig.cloudThinking` for the three value semantics.
        var cloudThinking: String
        /// Config-driven cloud reasoning-effort policy, threaded exactly like
        /// `cloudThinking`. See `PopConfig.cloudReasoningEffort` for the value
        /// semantics.
        var cloudReasoningEffort: String
        /// Applied to every request before the default `Authorization` header,
        /// so a configured `User-Agent` beats URLSession's stock one.
        var headers: [String: String] = [:]
    }

    let isHealthy: Bool
    let unhealthyReason: String

    private let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session

        let trimmed = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var healthy = true
        var reason = ""
        if trimmed.isEmpty {
            healthy = false
            reason = "baseURL is empty (set it in config.json)"
        } else if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
            healthy = false
            reason = "baseURL must start with http:// or https://, got \(trimmed)"
        }

        // KEY LEGIBILITY. A rebuild re-signs an ad-hoc binary, and macOS binds a
        // Keychain item's ACL to the code signature that created it — so a key
        // that WAS stored can become unreadable with no user action at all. The
        // only symptom was a silent missing `Authorization` header and a bare
        // `HTTP 401` at the far end. Saying so HERE, before any request, is what
        // turns "mysterious 401" into "paste the key again". NAMES and
        // presence only: never the key, never a fragment of it.
        let hasKey = !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        print("KEYCHAIN_READ=\(hasKey ? "present" : "missing") provider=openai-compat")
        fflush(stdout)
        if !hasKey {
            healthy = false
            reason = Self.missingKeyReason
        }
        // Assigned once, after every rule above has had its say: the last rule
        // to fire is the reason the user is told.
        isHealthy = healthy
        unhealthyReason = reason

        print("OPENAI_COMPAT_AVAILABILITY base=\(trimmed) model=\(configuration.model) healthy=\(isHealthy) reason=\(unhealthyReason)")
        fflush(stdout)
    }

    /// The one sentence that says what to DO about a missing key. Shared by the
    /// constructor, the HTTP status mapping and Settings, so the user can never
    /// be shown a dead end in one place and a different dead end in another.
    static let missingKeyReason =
        "no API key readable \u{2014} re-paste it in Settings "
        + "(a rebuild can invalidate the stored key; Developer ID signing fixes this permanently)"

    /// Builds the provider for the `openai-compat` config, pulling the key from
    /// the Keychain (never from config.json).
    static func fromConfig(_ config: PopConfig) -> OpenAICompatProvider {
        let key = KeychainStore.apiKey(for: config.provider) ?? ""
        return OpenAICompatProvider(configuration: Configuration(
            baseURL: config.baseURL,
            model: config.model,
            apiKey: key,
            temperature: config.temperature,
            cloudThinking: config.cloudThinking,
            cloudReasoningEffort: config.cloudReasoningEffort,
            headers: config.headers
        ))
    }

    /// The FALLBACK remote brain (M9): same endpoint/model/headers the user
    /// configured, but the key is read under the `openai-compat` account — that
    /// is where it is stored when the user configures the remote provider. The
    /// configured account is tried as a second chance so a key stored while
    /// `apple-fm` was selected still works.
    static func remoteFallback(_ config: PopConfig) -> OpenAICompatProvider {
        var key = KeychainStore.apiKey(for: "openai-compat")
        if key == nil || key?.isEmpty == true, config.provider != "openai-compat" {
            key = KeychainStore.apiKey(for: config.provider)
        }
        return OpenAICompatProvider(configuration: Configuration(
            baseURL: config.baseURL,
            model: config.model,
            apiKey: key ?? "",
            temperature: config.temperature,
            cloudThinking: config.cloudThinking,
            cloudReasoningEffort: config.cloudReasoningEffort,
            headers: config.headers
        ))
    }

    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        // Annotated explicitly: with a bare trailing closure the compiler can
        // also consider the `unfolding:` initializer and picks it.
        AsyncThrowingStream<ChatEvent, Error> { continuation in
            guard isHealthy else {
                continuation.finish(throwing: ProviderError.unhealthy(unhealthyReason))
                return
            }

            let task = Task {
                do {
                    // Once per request, so "which URL did it actually hit?" is
                    // answerable from a log when a base URL looks ignored.
                    print("OPENAI_URL=\(endpoint.absoluteString)")
                    fflush(stdout)
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    // Custom headers go on BEFORE the defaults, and nothing
                    // below overwrites them — that is what lets a configured
                    // `User-Agent` win over URLSession's stock one, which is
                    // the whole point for coding-plan endpoints. NAMES only are
                    // ever logged; a header value can carry a token.
                    if !configuration.headers.isEmpty {
                        print(
                            "OPENAI_HEADERS="
                                + configuration.headers.keys.sorted().joined(separator: ",")
                        )
                        fflush(stdout)
                    }
                    for (name, value) in configuration.headers {
                        request.setValue(value, forHTTPHeaderField: name)
                    }

                    if !configuration.apiKey.isEmpty {
                        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
                    }

                    let payload = Self.requestBody(
                        configuration: configuration,
                        messages: messages,
                        options: options,
                        tools: tools
                    )
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let body = String(decoding: await collect(bytes), as: UTF8.self)
                        print("OPENAI_COMPAT_HTTP status=\(http.statusCode) body=\(body)")
                        fflush(stdout)
                        // A bare "HTTP 401" tells the user nothing: the most
                        // likely cause by far is a key that this binary cannot
                        // read, so the 401 is translated into the SAME sentence
                        // the constructor and Settings use. The body is not
                        // shown to the user because it can echo request detail.
                        if http.statusCode == 401 {
                            throw ProviderError.unhealthy(Self.missingKeyReason)
                        }
                        throw ProviderError.unhealthy("HTTP \(http.statusCode)")
                    }

                    var full = ""
                    // Tool calls arrive as FRAGMENTS spread over many chunks
                    // (an index, a name on the first, arguments in pieces).
                    // They are accumulated per index and emitted once the
                    // arguments parse as complete JSON, so `AgentLoop` never
                    // sees a half-written argument object.
                    var pendingCalls: [Int: (id: String, name: String, arguments: String)] = [:]
                    for try await line in byteLines(bytes) {
                        guard line.hasPrefix("data:") else { continue }
                        let payloadText = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        if payloadText == "[DONE]" { break }

                        if let fragment = Self.toolCallFragment(fromSSELine: payloadText) {
                            var entry = pendingCalls[fragment.index] ?? ("", "", "")
                            if !fragment.id.isEmpty { entry.id = fragment.id }
                            entry.name += fragment.name
                            entry.arguments += fragment.arguments
                            pendingCalls[fragment.index] = entry
                            if let json = Self.completeArguments(entry.arguments) {
                                pendingCalls.removeValue(forKey: fragment.index)
                                continuation.yield(.toolCall(
                                    id: entry.id.isEmpty ? nil : entry.id,
                                    name: entry.name,
                                    arguments: json
                                ))
                            }
                        }

                        let piece = Self.delta(fromSSELine: payloadText)
                        guard let piece, !piece.isEmpty else { continue }
                        full += piece
                        continuation.yield(.delta(piece))
                    }
                    // Flush whatever never parsed as complete JSON, so a
                    // malformed call becomes tool-result text the model can
                    // read rather than a silently dropped request.
                    for callIndex in pendingCalls.keys.sorted() {
                        guard let entry = pendingCalls[callIndex] else { continue }
                        print("TOOL_CALL_PARTIAL name=\(entry.name) index=\(callIndex)")
                        fflush(stdout)
                        let json = Self.completeArguments(entry.arguments)
                            ?? .object(["_partial": .string(entry.arguments)])
                        continuation.yield(.toolCall(
                            id: entry.id.isEmpty ? nil : entry.id,
                            name: entry.name,
                            arguments: json
                        ))
                    }
                    continuation.yield(.done(full))
                    continuation.finish()
                } catch {
                    print("OPENAI_COMPAT_ERROR \(error)")
                    fflush(stdout)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Joins the configured base onto the chat-completions route.
    ///
    /// Whitespace is trimmed, ALL trailing slashes are stripped, and the route
    /// is appended exactly once — a base that already ends in the route is used
    /// as-is. That last case is why a naive `base + "/chat/completions"` fails
    /// with a doubled segment, and it is why the join lives in ONE place the
    /// probe can call directly instead of only inside a request.
    static func chatCompletionsURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // Accept a bare base ("http://host:1234") or a full endpoint already.
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        return URL(string: trimmed + "/chat/completions")
    }

    private var endpoint: URL {
        Self.chatCompletionsURL(baseURL: configuration.baseURL)
            ?? URL(string: "http://invalid.local/chat/completions")!
    }

    /// Pure payload builder: configuration in, request JSON body out. Static so
    /// a probe can assert the exact bytes a request would carry without a
    /// network call (`--test-thinking-param`).
    static func requestBody(
        configuration: Configuration,
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema]
    ) -> [String: Any] {
        // The system prompt is Pop's persona regardless of transport, so the
        // OpenAI-shaped path must send it as a real leading message.
        var conversation: [[String: Any]] = [
            ["role": "system", "content": AppleFMProvider.systemPrompt]
        ]
        conversation += messages
            // Drop only a duplicate of the persona that is already prepended
            // above. Any OTHER system message (e.g. the loop's mid-turn plan
            // nudge) is real instruction the model must receive, so it is
            // forwarded rather than silently discarded.
            .filter { !($0.role == .system && $0.text == AppleFMProvider.systemPrompt) }
            .map { message -> [String: Any] in
                switch message.role {
                case .tool:
                    // A tool RESULT must name the assistant call it answers,
                    // or the server cannot attach it and the model repeats the
                    // call instead of producing an answer.
                    var entry: [String: Any] = ["role": "tool", "content": message.text]
                    if let id = message.toolCallId { entry["tool_call_id"] = id }
                    return entry
                case .assistant where !(message.toolCalls ?? []).isEmpty:
                    // The assistant turn that REQUESTED the tools, echoed back
                    // in full so its `tool_calls` ids line up with the results.
                    return [
                        "role": "assistant",
                        "content": message.text,
                        "tool_calls": (message.toolCalls ?? []).map { call -> [String: Any] in
                            [
                                "id": call.id,
                                "type": "function",
                                "function": [
                                    "name": call.name,
                                    "arguments": call.arguments
                                ]
                            ]
                        }
                    ]
                default:
                    return ["role": message.role.rawValue, "content": message.text]
                }
            }

        var payload: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "messages": conversation
        ]
        if let temperature = options.temperature ?? configuration.temperature {
            payload["temperature"] = temperature
        }
        // Config-driven, exactly like temperature. z.ai runs thinking ON by
        // default for GLM-4.5+, so an explicit opt-out is what buys the speed;
        // "default" omits the field entirely for endpoints that reject unknown
        // keys. See `thinkingPayload`.
        if let thinking = thinkingPayload(cloudThinking: configuration.cloudThinking) {
            payload["thinking"] = thinking
        }
        // The separate TOP-LEVEL `reasoning_effort` string, config-driven like
        // thinking. Omitted entirely when nil so an endpoint that rejects
        // unknown fields is left untouched.
        if let effort = reasoningEffortPayload(configuration.cloudReasoningEffort) {
            payload["reasoning_effort"] = effort.foundationObject
        }
        if let maxTokens = options.maxTokens {
            payload["max_tokens"] = maxTokens
        }
        if !tools.isEmpty {
            // Built from the same fixed, alphabetically-sorted array every
            // turn, so these bytes are identical and the upstream prompt cache
            // stays warm.
            payload["tools"] = ToolRegistry.openAIToolsPayload()
        }
        return payload
    }

    /// Pure: maps the config's `cloudThinking` string to the optional z.ai
    /// `thinking` request object. `nil` means "omit the field entirely".
    ///
    ///   "enabled"  → `["type": "enabled"]`  (full reasoning)
    ///   "disabled" → `["type": "disabled"]` (the speed default)
    ///   "default"  → `nil`                  (omit; max compatibility)
    ///   anything else → treated as "disabled" (safe speed default; only
    ///                   reachable by hand-editing config.json).
    static func thinkingPayload(cloudThinking: String) -> [String: Any]? {
        switch cloudThinking {
        case "enabled": return ["type": "enabled"]
        case "default": return nil
        default: return ["type": "disabled"]
        }
    }

    /// Pure: maps the config's `cloudReasoningEffort` string to the optional
    /// top-level `reasoning_effort` value. `nil` means "omit the field".
    ///
    ///   "low"/"medium"/"high" → that string, sent verbatim
    ///   anything else         → `nil` (omit; "default" and typos alike)
    static func reasoningEffortPayload(_ value: String) -> JSONValue? {
        switch value {
        case "low", "medium", "high": return .string(value)
        default: return nil
        }
    }

    struct ToolCallFragment {
        var id: String
        var index: Int
        var name: String
        var arguments: String
    }

    /// Pulls one `choices[].delta.tool_calls[]` fragment out of an SSE payload.
    static func toolCallFragment(fromSSELine payload: String) -> ToolCallFragment? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let calls = delta["tool_calls"] as? [[String: Any]],
              let first = calls.first
        else {
            return nil
        }
        let function = first["function"] as? [String: Any] ?? [:]
        return ToolCallFragment(
            id: first["id"] as? String ?? "",
            index: (first["index"] as? Int) ?? 0,
            name: function["name"] as? String ?? "",
            arguments: function["arguments"] as? String ?? ""
        )
    }

    /// Arguments are complete once they parse. An empty string is not a call
    /// yet: the first fragment carries only the name.
    static func completeArguments(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONValue.decode(data)
    }

    /// Pulls `choices[0].delta.content` out of one SSE payload, tolerating the
    /// role-only first chunk and an error chunk.
    static func delta(fromSSELine payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let error = object["error"] as? [String: Any] {
            print("OPENAI_COMPAT_STREAM_ERROR \(error)")
            fflush(stdout)
            return nil
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any]
        else {
            return nil
        }
        return delta["content"] as? String
    }

    /// Drains an `AsyncBytes` body whole, used only for an error body.
    private func collect(_ bytes: URLSession.AsyncBytes) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
            }
        } catch {
            return data
        }
        return data
    }

    /// Splits an `AsyncBytes` body into SSE lines.
    private func byteLines(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await byte in bytes {
                        if byte == 0x0A {
                            let line = String(decoding: buffer, as: UTF8.self)
                            buffer.removeAll(keepingCapacity: true)
                            continuation.yield(line)
                        } else if byte != 0x0D {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}