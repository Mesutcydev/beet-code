import Foundation

enum RemoteLLMError: Error, LocalizedError, Equatable {
    case missingAPIKey(LLMProvider)
    case invalidConfiguration(String)
    case transport(String)
    case badStatus(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key configured for \(provider.displayName) — add one in Settings → BYOK Providers."
        case .invalidConfiguration(let detail):
            return "Invalid remote configuration: \(detail)"
        case .transport(let detail):
            return "Network error: \(detail)"
        case .badStatus(let code, let body):
            return "Provider returned HTTP \(code): \(String(body.prefix(300)))"
        case .cancelled:
            return "Generation cancelled."
        }
    }
}

/// Streaming chat client for OpenAI-compatible endpoints (OpenAI, DeepSeek,
/// LongCat, Alibaba DashScope, OpenRouter) and Gemini's native API.
/// Pure Foundation: URLSession + manual SSE parsing.
enum RemoteLLMClient {

    // MARK: Wire types (OpenAI)

    struct OpenAIMessage: Codable, Sendable, Equatable {
        var role: String
        var content: String
    }

    struct OpenAIRequest: Encodable, Sendable {
        var model: String
        var messages: [OpenAIMessage]
        var temperature: Double?
        var max_tokens: Int?
        /// o-series / gpt-5-era models reject `max_tokens`; when the model
        /// looks like a reasoning model the caller sets this instead.
        var max_completion_tokens: Int?
        var stream: Bool = true
        var tools: [NativeToolBridge.OpenAITool]?
        /// LongCat exposes its reasoning switch as an OpenAI-compatible
        /// extension. Keep it provider-gated so strict OpenAI-compatible
        /// servers never receive an unknown field.
        var thinking: Thinking?
        /// Standard OpenAI-compatible reasoning control. It is optional so
        /// ordinary models receive the exact same payload as before.
        var reasoning_effort: String? = nil
        /// Asks OpenAI-compatible servers for a final usage chunk — powers
        /// truthful token stats instead of chunk counting.
        var stream_options: StreamOptions?
        struct Thinking: Codable, Sendable {
            var type: String
        }
        struct StreamOptions: Codable, Sendable {
            var include_usage: Bool = true
        }
    }

    /// OpenAI Responses-compatible request. OpenCode and several newer
    /// gateways expose Responses as a separate route instead of accepting a
    /// Chat Completions payload. Keeping this wire type separate prevents
    /// provider-specific fields from leaking into ordinary chat requests.
    struct ResponsesRequest: Encodable, Sendable {
        var model: String
        var input: [OpenAIMessage]
        var temperature: Double?
        var max_output_tokens: Int?
        var stream: Bool = true
        var tools: [ResponsesTool]?
        var reasoning: Reasoning? = nil

        struct Reasoning: Encodable, Sendable {
            var effort: String
        }

        struct ResponsesTool: Encodable, Sendable {
            var type: String = "function"
            var name: String
            var description: String
            var parameters: NativeToolBridge.JSONBox
        }
    }

    struct OpenAIChunk: Codable, Sendable {
        struct Choice: Codable, Sendable {
            struct Delta: Codable, Sendable {
                var content: String?
                var role: String?
                /// DeepSeek reasoner / OpenAI o-series reasoning deltas.
                var reasoning_content: String?
                var reasoning: String?
                var tool_calls: [ToolCallDelta]?
            }
            struct ToolCallDelta: Codable, Sendable {
                var index: Int?
                var function: FunctionDelta?
                struct FunctionDelta: Codable, Sendable {
                    var name: String?
                    var arguments: String?
                }
            }
            var delta: Delta?
            var finish_reason: String?
        }
        var choices: [Choice]?
        var error: OpenAIErrorBody?
        /// Final-chunk usage (requires stream_options.include_usage).
        var usage: Usage?
        struct Usage: Codable, Sendable {
            var prompt_tokens: Int?
            var completion_tokens: Int?
        }
    }

    struct OpenAIErrorBody: Codable, Sendable {
        var message: String?
    }

    // MARK: Wire types (Gemini)

    struct GeminiRequest: Codable, Sendable {
        struct Content: Codable, Sendable {
            var role: String
            var parts: [Part]
        }
        struct Part: Codable, Sendable {
            var text: String?
            var functionCall: FunctionCall? = nil
            /// Gemini thought summaries are marked on response parts. They
            /// must not be merged into the visible answer text.
            var thought: Bool? = nil
            var thoughtSignature: String? = nil

            struct FunctionCall: Codable, Sendable {
                var name: String?
                var args: NativeToolBridge.JSONBox?
            }
        }
        struct GenerationConfig: Codable, Sendable {
            var temperature: Double?
            var maxOutputTokens: Int?
            var thinkingConfig: ThinkingConfig?

            struct ThinkingConfig: Codable, Sendable {
                var thinkingBudget: Int?
                var thinkingLevel: String?
            }
        }
        var contents: [Content]
        var tools: [NativeToolBridge.GeminiTool]? = nil
        /// Proper home for the system prompt (the old code folded it into
        /// the first user turn, degrading instruction adherence).
        var systemInstruction: Content?
        var generationConfig: GenerationConfig?
    }

    struct GeminiChunk: Codable, Sendable {
        struct Candidate: Codable, Sendable {
            struct Content: Codable, Sendable {
                var parts: [GeminiRequest.Part]?
            }
            var content: Content?
            var finishReason: String?
        }
        var candidates: [Candidate]?
        var error: GeminiErrorBody?
        /// Token accounting Gemini emits with streamed responses.
        var usageMetadata: UsageMetadata?
        struct UsageMetadata: Codable, Sendable {
            var promptTokenCount: Int?
            var candidatesTokenCount: Int?
        }
    }

    struct GeminiErrorBody: Codable, Sendable {
        struct Status: Codable, Sendable {
            var message: String?
        }
        var status: Status?
        var message: String?
    }

    // MARK: Wire types (Anthropic Messages API)

    struct AnthropicMessage: Codable, Sendable, Equatable {
        var role: String
        /// Content is a string for plain text; the native tool_use/
        /// tool_result blocks use the parts form, which the client builds
        /// via JSONSerialization when a tool pairing is present.
        var content: String
    }

    struct AnthropicRequest: Encodable, Sendable {
        var model: String
        var max_tokens: Int  // mandatory on Anthropic
        var system: String?
        var messages: [AnthropicMessage]
        var temperature: Double?
        var stream: Bool = true
        var tools: [NativeToolBridge.AnthropicTool]?
        var output_config: OutputConfig? = nil

        struct OutputConfig: Encodable, Sendable {
            var effort: String
        }
    }

    struct AnthropicChunk: Codable, Sendable {
        struct Delta: Codable, Sendable {
            var type: String?
            var text: String?
            var thinking: String?
            var partial_json: String?
        }
        struct ContentBlock: Codable, Sendable {
            var type: String?
            var name: String?
            /// Some Anthropic-compatible gateways put the first thinking
            /// text on the block-start event instead of a thinking_delta.
            var thinking: String?
        }
        struct Usage: Codable, Sendable {
            var input_tokens: Int?
            var output_tokens: Int?
        }
        struct MessageInfo: Codable, Sendable {
            var usage: Usage?
        }
        var type: String?
        var delta: Delta?
        var content_block: ContentBlock?
        var index: Int?
        var usage: Usage?
        var message: MessageInfo?
        var error: OpenAIErrorBody?
    }

    // MARK: Public API

    static let userAgent = "BeetCode/0.8.5 (macOS coding agent)"

    // MARK: Message preparation (P2/P7 — provider-safe role mapping)

    /// Maps engine turns to OpenAI-format messages. Tool turns have no
    /// `tool_call_id` pairing in this architecture (the loop uses a
    /// text-based tool protocol), so they travel as marked user messages —
    /// valid on every OpenAI-compatible server, whereas a raw `tool` role
    /// without a preceding `tool_calls` entry 400s on OpenAI/Azure.
    static func prepareOpenAIMessages(_ turns: [ChatTurn]) -> [OpenAIMessage] {
        turns.map { turn in
            switch turn.role {
            case .tool:
                OpenAIMessage(role: "user", content: "[tool result] " + turn.content)
            default:
                OpenAIMessage(role: turn.role.rawValue, content: turn.content)
            }
        }
    }

    /// Gemini payload: system prompt in `systemInstruction` (not folded into
    /// user text), user/model roles, tool results as marked user text, and
    /// adjacent same-role turns merged — Gemini rejects non-alternating roles.
    static func prepareGeminiPayload(_ turns: [ChatTurn]) -> (system: String?, contents: [GeminiRequest.Content]) {
        var systemText = ""
        var contents: [GeminiRequest.Content] = []
        for turn in turns {
            switch turn.role {
            case .system:
                systemText += turn.content + "\n"
            case .assistant:
                appendMerged(role: "model", text: turn.content, into: &contents)
            default:
                let text = turn.role == .tool ? "[tool result] " + turn.content : turn.content
                appendMerged(role: "user", text: text, into: &contents)
            }
        }
        let system = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (system.isEmpty ? nil : system, contents)
    }

    private static func appendMerged(role: String, text: String, into contents: inout [GeminiRequest.Content]) {
        if var last = contents.last, last.role == role {
            last.parts.append(.init(text: "\n" + text))
            contents[contents.count - 1] = last
        } else {
            contents.append(.init(role: role, parts: [.init(text: text)]))
        }
    }

    /// Anthropic payload: system prompt top-level, strict user/assistant
    /// alternation (merged), first message forced to user.
    static func prepareAnthropicPayload(_ turns: [ChatTurn]) -> (system: String?, messages: [AnthropicMessage]) {
        var systemText = ""
        var messages: [AnthropicMessage] = []
        for turn in turns {
            switch turn.role {
            case .system:
                systemText += turn.content + "\n"
            case .assistant:
                if var last = messages.last, last.role == "assistant" {
                    last.content += "\n" + turn.content
                    messages[messages.count - 1] = last
                } else {
                    messages.append(.init(role: "assistant", content: turn.content))
                }
            default:
                let text = turn.role == .tool ? "[tool result] " + turn.content : turn.content
                if var last = messages.last, last.role == "user" {
                    last.content += "\n" + text
                    messages[messages.count - 1] = last
                } else {
                    messages.append(.init(role: "user", content: text))
                }
            }
        }
        if messages.first?.role != "user" {
            messages.insert(.init(role: "user", content: "(continue)"), at: 0)
        }
        let system = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (system.isEmpty ? nil : system, messages)
    }

    // MARK: Model-family heuristics (P3/P8)

    /// o-series and gpt-5-era models reject `max_tokens`.
    static func usesMaxCompletionTokens(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
            || m.hasPrefix("gpt-5") || m.hasPrefix("codex-")
    }

    /// Models that reject an explicit `temperature` (o-series wants the
    /// default; DeepSeek reasoner refuses non-default values).
    static func omitsTemperature(_ model: String) -> Bool {
        let m = model.lowercased()
        return usesMaxCompletionTokens(m) || m.contains("reasoner")
    }

    // MARK: Shared streaming plumbing (P6 watchdog + one bounded retry)

    private static func retryDelay(_ http: HTTPURLResponse) -> TimeInterval {
        if let header = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header) {
            return min(max(seconds, 1), 8)
        }
        return 2
    }

    private static func errorDetail(from body: String) -> String? {
        guard let data = body.data(using: .utf8) else { return nil }
        if let openai = try? JSONDecoder().decode(OpenAIChunk.self, from: data),
           let message = openai.error?.message { return message }
        if let gemini = try? JSONDecoder().decode(GeminiChunk.self, from: data),
           let message = gemini.error?.message ?? gemini.error?.status?.message { return message }
        if let anthropic = try? JSONDecoder().decode(AnthropicChunk.self, from: data),
           let message = anthropic.error?.message { return message }
        return nil
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// Executes a streaming request with: one bounded retry on 429/503
    /// (honoring Retry-After, capped at 8s), byte-level SSE consumption
    /// with an inactivity watchdog, and UTF-8-safe decoding.
    private static func runStreamingRequest(
        makeRequest: @escaping @Sendable () throws -> URLRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        onUsage: (@Sendable (UsageInfo) -> Void)?
    ) {
        let task = Task {
            var attempt = 0
            while true {
                do {
                    let request = try makeRequest()
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw RemoteLLMError.transport("non-HTTP response")
                    }
                    if http.statusCode == 200 {
                        try await Self.consumeSSE(
                            bytes: bytes,
                            onText: { continuation.yield($0) },
                            onUsage: onUsage)
                        continuation.finish()
                        return
                    }
                    var raw: [UInt8] = []
                    for try await byte in bytes {
                        raw.append(byte)
                        if raw.count > 8000 { break }
                    }
                    let body = String(decoding: raw, as: UTF8.self)
                    if attempt == 0, http.statusCode == 429 || http.statusCode == 503 {
                        attempt += 1
                        try await Task.sleep(for: .seconds(retryDelay(http)))
                        continue
                    }
                    let detail = errorDetail(from: body) ?? String(body.prefix(300))
                    throw RemoteLLMError.badStatus(http.statusCode, detail)
                } catch is CancellationError {
                    continuation.finish(throwing: RemoteLLMError.cancelled)
                    return
                } catch let error as RemoteLLMError {
                    continuation.finish(throwing: error)
                    return
                } catch {
                    continuation.finish(throwing: RemoteLLMError.transport(String(describing: error)))
                    return
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }

    /// Streams a chat completion from an OpenAI-compatible endpoint.
    /// Yields content deltas; finish without error = completion.
    static func stream(
        endpoint: RemoteEndpoint,
        apiKey: String,
        model: String,
        turns: [ChatTurn],
        temperature: Double?,
        maxTokens: Int?,
        reasoningEffort: String? = nil,
        tools: [NativeToolSpec] = [],
        onUsage: (@Sendable (UsageInfo) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        guard let baseURL = endpoint.effectiveBaseURL else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: RemoteLLMError.invalidConfiguration("no endpoint URL"))
            }
        }
        switch endpoint.effectiveProtocol {
        case .gemini:
            return streamGemini(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                turns: turns,
                temperature: temperature,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                tools: tools,
                headers: endpoint.headers,
                onUsage: onUsage)
        case .anthropicMessages:
            return streamAnthropic(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                turns: turns,
                temperature: temperature,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                tools: tools,
                headers: endpoint.headers,
                onUsage: onUsage)
        case .openAIResponses:
            return streamOpenAIResponses(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                turns: turns,
                temperature: temperature,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                tools: tools,
                headers: endpoint.headers,
                onUsage: onUsage)
        case .openAIChatCompletions:
            return streamOpenAICompatible(
                provider: endpoint.provider,
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                turns: turns,
                temperature: temperature,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                tools: tools,
                headers: endpoint.headers,
                onUsage: onUsage)
        }
    }

    static func streamOpenAICompatible(
        provider: LLMProvider,
        baseURL: URL,
        apiKey: String,
        model: String,
        turns: [ChatTurn],
        temperature: Double?,
        maxTokens: Int?,
        reasoningEffort: String? = nil,
        tools: [NativeToolSpec] = [],
        headers: [String: String] = [:],
        onUsage: (@Sendable (UsageInfo) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let first = streamOpenAIOnce(
                        provider: provider, baseURL: baseURL, apiKey: apiKey,
                        model: model, turns: turns, temperature: temperature,
                        maxTokens: maxTokens, reasoningEffort: reasoningEffort,
                        includeStreamOptions: true,
                        tools: tools, headers: headers, onUsage: onUsage)
                    for try await chunk in first {
                        if Task.isCancelled { throw RemoteLLMError.cancelled }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch RemoteLLMError.badStatus(let code, _) where code == 400 {
                    do {
                        let retry = streamOpenAIOnce(
                            provider: provider, baseURL: baseURL, apiKey: apiKey,
                            model: model, turns: turns, temperature: temperature,
                            maxTokens: maxTokens, reasoningEffort: reasoningEffort,
                            includeStreamOptions: false,
                            tools: tools, headers: headers, onUsage: onUsage)
                        for try await chunk in retry {
                            if Task.isCancelled { throw RemoteLLMError.cancelled }
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch RemoteLLMError.badStatus(400, _) where !tools.isEmpty {
                        // Older proxies / Ollama builds reject `tools`.
                        do {
                            let plain = streamOpenAIOnce(
                                provider: provider, baseURL: baseURL, apiKey: apiKey,
                                model: model, turns: turns, temperature: temperature,
                                maxTokens: maxTokens, reasoningEffort: reasoningEffort,
                                includeStreamOptions: false,
                                tools: [], headers: headers, onUsage: onUsage)
                            for try await chunk in plain {
                                if Task.isCancelled { throw RemoteLLMError.cancelled }
                                continuation.yield(chunk)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One OpenAI-compatible streaming attempt. `includeStreamOptions` toggles
    /// the `stream_options: {include_usage}` field strict servers reject.
    private static func streamOpenAIOnce(
        provider: LLMProvider,
        baseURL: URL,
        apiKey: String,
        model: String,
        turns: [ChatTurn],
        temperature: Double?,
        maxTokens: Int?,
        reasoningEffort: String? = nil,
        includeStreamOptions: Bool,
        tools: [NativeToolSpec] = [],
        headers: [String: String] = [:],
        onUsage: (@Sendable (UsageInfo) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let messages = prepareOpenAIMessages(turns)
            let reasoningCap = usesMaxCompletionTokens(model)
            let reasoningEnabled = UserDefaults.standard.object(forKey: "showReasoning") as? Bool ?? true
            let body = OpenAIRequest(
                model: model,
                messages: messages,
                temperature: omitsTemperature(model) ? nil : temperature,
                max_tokens: reasoningCap ? nil : maxTokens,
                max_completion_tokens: reasoningCap ? maxTokens : nil,
                stream: true,
                tools: tools.isEmpty ? nil : NativeToolBridge.openAITools(from: tools),
                thinking: provider == .longCat
                    ? .init(type: reasoningEnabled ? "enabled" : "disabled")
                    : nil,
                reasoning_effort: reasoningEffort,
                stream_options: includeStreamOptions ? .init() : nil)
            runStreamingRequest(makeRequest: {
                var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                request.httpMethod = "POST"
                apply(headers, to: &request)
                if !apiKey.isEmpty, request.value(forHTTPHeaderField: "Authorization") == nil,
                   request.value(forHTTPHeaderField: "x-api-key") == nil {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 120
                // OpenRouter wants its app identity header for free-tier usage.
                if provider == .openRouter {
                    request.setValue("Beet Code", forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("Beet Code", forHTTPHeaderField: "X-Title")
                }
                request.httpBody = try JSONEncoder().encode(body)
                return request
            }, continuation: continuation, onUsage: onUsage)
        }
    }

    /// Streams an OpenAI Responses-compatible model. The Responses wire
    /// format is deliberately separate from Chat Completions because the two
    /// APIs use different request keys and tool shapes, even when a gateway
    /// exposes both below the same base URL.
    static func streamOpenAIResponses(
        baseURL: URL,
        apiKey: String,
        model: String,
        turns: [ChatTurn],
        temperature: Double?,
        maxTokens: Int?,
        reasoningEffort: String? = nil,
        tools: [NativeToolSpec] = [],
        headers: [String: String] = [:],
        onUsage: (@Sendable (UsageInfo) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let responseTools = tools.map { spec in
                ResponsesRequest.ResponsesTool(
                    name: spec.name,
                    description: spec.description,
                    parameters: NativeToolBridge.JSONBox.parse(spec.schemaText))
            }
            let body = ResponsesRequest(
                model: model,
                input: prepareOpenAIMessages(turns),
                temperature: omitsTemperature(model) ? nil : temperature,
                max_output_tokens: maxTokens,
                stream: true,
                tools: responseTools.isEmpty ? nil : responseTools,
                reasoning: reasoningEffort.map { .init(effort: $0) })
            runStreamingRequest(makeRequest: {
                var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
                request.httpMethod = "POST"
                apply(headers, to: &request)
                if !apiKey.isEmpty, request.value(forHTTPHeaderField: "Authorization") == nil,
                   request.value(forHTTPHeaderField: "x-api-key") == nil {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 120
                request.httpBody = try JSONEncoder().encode(body)
                return request
            }, continuation: continuation, onUsage: onUsage)
        }
    }

    /// Streams a chat completion from Gemini's native API. The API key
    /// travels in the `x-goog-api-key` header — never in the URL, so it
    /// cannot leak into request logs.
    static func streamGemini(
        baseURL: URL,
        apiKey: String,
        model: String,
        turns: [ChatTurn],
        temperature: Double?,
        maxTokens: Int?,
        reasoningEffort: String? = nil,
        tools: [NativeToolSpec] = [],
        headers: [String: String] = [:],
        onUsage: (@Sendable (UsageInfo) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let (system, contents) = prepareGeminiPayload(turns)
            let modelID = normalizedGeminiModelID(model)
            let url = baseURL
                .appendingPathComponent("models/\(modelID):streamGenerateContent")
                .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])
            let body = GeminiRequest(
                contents: contents,
                tools: tools.isEmpty ? nil : NativeToolBridge.geminiTools(from: tools),
                systemInstruction: system.map { .init(role: "user", parts: [.init(text: $0)]) },
                generationConfig: .init(
                    temperature: temperature,
                    maxOutputTokens: maxTokens,
                    thinkingConfig: geminiThinkingConfig(model: model, effort: reasoningEffort)))
            runStreamingRequest(makeRequest: {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                apply(headers, to: &request)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !apiKey.isEmpty, request.value(forHTTPHeaderField: "x-goog-api-key") == nil {
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                }
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 120
                request.httpBody = try JSONEncoder().encode(body)
                return request
            }, continuation: continuation, onUsage: onUsage)
        }
    }

    /// Streams a chat completion from Anthropic's Messages API.
    /// `max_tokens` is mandatory on Anthropic; 8192 is a safe default cap.
    static func streamAnthropic(
        baseURL: URL,
        apiKey: String,
        model: String,
        turns: [ChatTurn],
        temperature: Double?,
        maxTokens: Int?,
        reasoningEffort: String? = nil,
        tools: [NativeToolSpec] = [],
        headers: [String: String] = [:],
        onUsage: (@Sendable (UsageInfo) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let (system, messages) = prepareAnthropicPayload(turns)
            let body = AnthropicRequest(
                model: model,
                max_tokens: maxTokens ?? 8192,
                system: system,
                messages: messages,
                temperature: omitsTemperature(model) ? nil : temperature,
                stream: true,
                tools: tools.isEmpty ? nil : NativeToolBridge.anthropicTools(from: tools),
                output_config: reasoningEffort.map { .init(effort: $0) })
            runStreamingRequest(makeRequest: {
                var request = URLRequest(url: baseURL.appendingPathComponent("messages"))
                request.httpMethod = "POST"
                apply(headers, to: &request)
                if !apiKey.isEmpty, request.value(forHTTPHeaderField: "x-api-key") == nil,
                   request.value(forHTTPHeaderField: "Authorization") == nil {
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                }
                if request.value(forHTTPHeaderField: "anthropic-version") == nil {
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                }
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 120
                request.httpBody = try JSONEncoder().encode(body)
                return request
            }, continuation: continuation, onUsage: onUsage)
        }
    }

    /// Gemini 3 exposes named thinking levels while Gemini 2.5 uses a token
    /// budget. The UI keeps one effort vocabulary, but the wire payload stays
    /// native to the selected model family.
    private static func geminiThinkingConfig(
        model: String,
        effort: String?
    ) -> GeminiRequest.GenerationConfig.ThinkingConfig? {
        guard let effort = effort.flatMap(ReasoningEffort.init) else { return nil }
        let modelID = model.lowercased()
        if modelID.contains("gemini-2.5") {
            let budget: Int
            switch effort.rawValue {
            case "none": budget = 0
            case "minimal", "low": budget = 1_024
            case "medium": budget = 8_192
            case "high", "xhigh", "max": budget = 24_576
            default: return nil
            }
            return .init(thinkingBudget: budget, thinkingLevel: nil)
        }
        guard modelID.contains("gemini-3") else { return nil }
        let level = effort.rawValue == "none" ? "minimal" : effort.rawValue
        return .init(thinkingBudget: nil, thinkingLevel: level)
    }

    /// Non-streaming connectivity probe used by the Settings "Test" button.
    /// Sends a tiny completion request and returns the model id the provider
    /// answered with. Throws `RemoteLLMError` with the provider's message on
    /// any failure (bad key, unknown model, transport).
    ///
    /// The probe omits `temperature` entirely (P3): reasoning models
    /// (DeepSeek reasoner, OpenAI o-series) reject explicit temperature
    /// values, which made the Test button fail for models that worked fine
    /// in real chat.
    static func testConnection(
        endpoint: RemoteEndpoint,
        apiKey: String
    ) async throws -> String {
        guard let base = endpoint.effectiveBaseURL else {
            throw RemoteLLMError.invalidConfiguration("no endpoint URL")
        }
        let request: URLRequest
        switch endpoint.effectiveProtocol {
        case .gemini:
            let modelID = normalizedGeminiModelID(endpoint.model)
            var r = URLRequest(url: base.appendingPathComponent("models/\(modelID):generateContent"))
            r.httpMethod = "POST"
            apply(endpoint.headers, to: &r)
            if !apiKey.isEmpty, r.value(forHTTPHeaderField: "x-goog-api-key") == nil {
                r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            }
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 30
            r.httpBody = try JSONEncoder().encode(GeminiRequest(
                contents: [.init(role: "user", parts: [.init(text: "ping")])],
                generationConfig: .init(maxOutputTokens: 4)))
            request = r
        case .anthropicMessages:
            var r = URLRequest(url: base.appendingPathComponent("messages"))
            r.httpMethod = "POST"
            apply(endpoint.headers, to: &r)
            if !apiKey.isEmpty, r.value(forHTTPHeaderField: "x-api-key") == nil,
               r.value(forHTTPHeaderField: "Authorization") == nil {
                r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            if r.value(forHTTPHeaderField: "anthropic-version") == nil {
                r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 30
            r.httpBody = try JSONEncoder().encode(AnthropicRequest(
                model: endpoint.model,
                max_tokens: 4,
                messages: [.init(role: "user", content: "ping")],
                stream: false))
            request = r
        case .openAIResponses:
            var r = URLRequest(url: base.appendingPathComponent("responses"))
            r.httpMethod = "POST"
            apply(endpoint.headers, to: &r)
            if !apiKey.isEmpty, r.value(forHTTPHeaderField: "Authorization") == nil,
               r.value(forHTTPHeaderField: "x-api-key") == nil {
                r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 30
            r.httpBody = try JSONEncoder().encode(ResponsesRequest(
                model: endpoint.model,
                input: [.init(role: "user", content: "ping")],
                max_output_tokens: 4,
                stream: false))
            request = r
        case .openAIChatCompletions:
            var r = URLRequest(url: base.appendingPathComponent("chat/completions"))
            r.httpMethod = "POST"
            apply(endpoint.headers, to: &r)
            if !apiKey.isEmpty, r.value(forHTTPHeaderField: "Authorization") == nil,
               r.value(forHTTPHeaderField: "x-api-key") == nil {
                r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 30
            let reasoningCap = usesMaxCompletionTokens(endpoint.model)
            r.httpBody = try JSONEncoder().encode(OpenAIRequest(
                model: endpoint.model,
                messages: [.init(role: "user", content: "ping")],
                max_tokens: reasoningCap ? nil : 4,
                max_completion_tokens: reasoningCap ? 4 : nil,
                stream: false))
            request = r
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            let detail = errorDetail(from: text) ?? String(text.prefix(220))
            throw RemoteLLMError.badStatus(http.statusCode, detail)
        }
        if let chunk = try? JSONDecoder().decode(OpenAICompletion.self, from: data) {
            return chunk.model ?? endpoint.model
        }
        return endpoint.model
    }

    static func testConnection(
        provider: LLMProvider,
        apiKey: String,
        model: String
    ) async throws -> String {
        let request: URLRequest
        let bodyData: Data
        switch provider {
        case .gemini:
            guard let base = provider.geminiBaseURL else {
                throw RemoteLLMError.invalidConfiguration("no endpoint URL")
            }
            let modelID = normalizedGeminiModelID(model)
            let url = base.appendingPathComponent("models/\(modelID):generateContent")
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 30
            let body = GeminiRequest(
                contents: [.init(role: "user", parts: [.init(text: "ping")])],
                generationConfig: .init(maxOutputTokens: 4))
            bodyData = try JSONEncoder().encode(body)
            r.httpBody = bodyData
            request = r
        case .anthropic:
            guard let base = provider.anthropicBaseURL else {
                throw RemoteLLMError.invalidConfiguration("no endpoint URL")
            }
            var r = URLRequest(url: base.appendingPathComponent("messages"))
            r.httpMethod = "POST"
            r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 30
            let body = AnthropicRequest(
                model: model,
                max_tokens: 4,
                messages: [.init(role: "user", content: "ping")],
                stream: false)
            bodyData = try JSONEncoder().encode(body)
            r.httpBody = bodyData
            request = r
        default:
            guard let base = provider.openAICompatibleBaseURL else {
                throw RemoteLLMError.invalidConfiguration(
                    provider == .custom ? "no custom base URL configured" : "no endpoint URL")
            }
            var r = URLRequest(url: base.appendingPathComponent("chat/completions"))
            r.httpMethod = "POST"
            if !apiKey.isEmpty {
                r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 30
            if provider == .openRouter {
                r.setValue("Beet Code", forHTTPHeaderField: "HTTP-Referer")
                r.setValue("Beet Code", forHTTPHeaderField: "X-Title")
            }
            let body = OpenAIRequest(
                model: model,
                messages: [.init(role: "user", content: "ping")],
                max_tokens: 4,
                stream: false)
            bodyData = try JSONEncoder().encode(body)
            r.httpBody = bodyData
            request = r
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            let detail = errorDetail(from: text) ?? String(text.prefix(220))
            throw RemoteLLMError.badStatus(http.statusCode, detail)
        }
        if let chunk = try? JSONDecoder().decode(OpenAICompletion.self, from: data) {
            return chunk.model ?? model
        }
        if let gemini = try? JSONDecoder().decode(GeminiCompletion.self, from: data),
           gemini.candidates?.isEmpty == false {
            return model
        }
        return model
    }

    // MARK: Live model discovery (P10)

    static func fetchModels(
        endpoint: RemoteEndpoint,
        apiKey: String?,
        session: URLSession = .shared
    ) async throws -> [String] {
        try await fetchModelProfiles(endpoint: endpoint, apiKey: apiKey, session: session).map(\.model)
    }

    /// Model discovery for imported providers. It uses the imported base URL
    /// and headers, then carries the provider id through to the picker so two
    /// providers serving the same model id never collide.
    static func fetchModelProfiles(
        endpoint: RemoteEndpoint,
        apiKey: String?,
        session: URLSession = .shared
    ) async throws -> [RemoteModelProfile] {
        guard let base = endpoint.effectiveBaseURL else {
            throw RemoteLLMError.invalidConfiguration("no models endpoint")
        }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = 15
        apply(endpoint.headers, to: &request)
        if let apiKey, !apiKey.isEmpty,
           request.value(forHTTPHeaderField: "Authorization") == nil,
           request.value(forHTTPHeaderField: "x-api-key") == nil,
           request.value(forHTTPHeaderField: "x-goog-api-key") == nil {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await get(request, provider: endpoint.provider, session: session)

        let profiles: [RemoteModelProfile]
        switch endpoint.effectiveProtocol {
        case .gemini:
            let decoded = try JSONDecoder().decode(GeminiModels.self, from: data)
            profiles = decoded.models.compactMap { entry in
                guard let model = geminiModelID(from: entry) else { return nil }
                return RemoteModelProfile(
                    provider: endpoint.provider,
                    model: model,
                    displayName: entry.displayName,
                    contextWindow: entry.inputTokenLimit,
                    maxOutputTokens: entry.outputTokenLimit,
                    supportsVision: entry.supportsVision,
                    supportsTools: entry.supportedGenerationMethods.contains("generateContent"),
                    supportsTemperature: true,
                    providerKey: endpoint.providerID,
                    providerDisplayName: endpoint.effectiveDisplayName,
                    apiProtocol: endpoint.effectiveProtocol,
                    baseURL: base.absoluteString,
                    headers: endpoint.headers,
                    apiKey: apiKey)
            }
        case .anthropicMessages:
            let decoded = try JSONDecoder().decode(AnthropicModels.self, from: data)
            profiles = decoded.data.compactMap { model in
                guard let id = model.id else { return nil }
                return RemoteModelProfile(
                    provider: endpoint.provider,
                    model: id,
                    providerKey: endpoint.providerID,
                    providerDisplayName: endpoint.effectiveDisplayName,
                    apiProtocol: endpoint.effectiveProtocol,
                    baseURL: base.absoluteString,
                    headers: endpoint.headers,
                    apiKey: apiKey)
            }
        default:
            profiles = try compatibleModelProfiles(from: data, provider: endpoint.provider).map { profile in
                var profile = profile
                profile.providerKey = endpoint.providerID
                profile.providerDisplayName = endpoint.effectiveDisplayName
                profile.apiProtocol = endpoint.effectiveProtocol
                profile.baseURL = base.absoluteString
                profile.headers = endpoint.headers
                profile.apiKey = apiKey
                return profile
            }
        }
        return deduplicatedProfiles(profiles)
    }

    /// Fetches the provider's live model catalog. Errors are preserved so the
    /// settings UI can tell the user whether the key, endpoint, or provider
    /// response is the problem instead of silently looking like an empty list.
    static func fetchModels(
        provider: LLMProvider,
        apiKey: String?,
        session: URLSession = .shared
    ) async throws -> [String] {
        try await fetchModelProfiles(provider: provider, apiKey: apiKey, session: session).map(\.model)
    }

    /// Fetches live model metadata where the provider exposes it. OpenAI-
    /// compatible and Anthropic catalogs generally return only ids, so those
    /// profiles intentionally leave capabilities unknown until an override is
    /// supplied.
    static func fetchModelProfiles(
        provider: LLMProvider,
        apiKey: String?,
        session: URLSession = .shared
    ) async throws -> [RemoteModelProfile] {
        switch provider {
        case .gemini:
            guard let base = provider.modelsURL else {
                throw RemoteLLMError.invalidConfiguration("no Gemini models endpoint")
            }
            var models: [RemoteModelProfile] = []
            var pageToken: String?
            // The API is paginated. A bounded loop prevents a malformed
            // nextPageToken from turning Settings into an unbounded request.
            for _ in 0..<10 {
                var query = [URLQueryItem(name: "pageSize", value: "200")]
                if let pageToken, !pageToken.isEmpty {
                    query.append(URLQueryItem(name: "pageToken", value: pageToken))
                }
                var request = URLRequest(url: base.appending(queryItems: query))
                request.timeoutInterval = 15
                if let apiKey, !apiKey.isEmpty {
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                }
                let data = try await get(request, provider: provider, session: session)
                let decoded = try JSONDecoder().decode(GeminiModels.self, from: data)
                models.append(contentsOf: decoded.models.compactMap { entry in
                    guard let model = Self.geminiModelID(from: entry) else { return nil }
                    return RemoteModelProfile(
                        provider: provider,
                        model: model,
                        displayName: entry.displayName,
                        contextWindow: entry.inputTokenLimit,
                        maxOutputTokens: entry.outputTokenLimit,
                        supportsVision: entry.supportsVision,
                        supportsTools: entry.supportedGenerationMethods.contains("generateContent"),
                        supportsReasoning: nil,
                        supportsTemperature: true)
                })
                guard let next = decoded.nextPageToken, !next.isEmpty else { break }
                pageToken = next
            }
            return deduplicatedProfiles(models)
        case .anthropic:
            guard let base = provider.modelsURL else {
                throw RemoteLLMError.invalidConfiguration("no Anthropic models endpoint")
            }
            var request = URLRequest(url: base
                .appending(queryItems: [URLQueryItem(name: "limit", value: "100")]))
            request.timeoutInterval = 15
            if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let data = try await get(request, provider: provider, session: session)
            let decoded = try JSONDecoder().decode(AnthropicModels.self, from: data)
            return deduplicatedProfiles(decoded.data.compactMap { model in
                guard let id = model.id else { return nil }
                return RemoteModelProfile(provider: provider, model: id)
            })
        default:
            guard let base = provider.modelsURL else {
                throw RemoteLLMError.invalidConfiguration(
                    provider == .custom ? "no custom base URL configured" : "no models endpoint")
            }
            var request = URLRequest(url: base)
            request.timeoutInterval = 15
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if provider == .openRouter {
                request.setValue("Beet Code", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("Beet Code", forHTTPHeaderField: "X-Title")
            }
            let data = try await get(request, provider: provider, session: session)
            return deduplicatedProfiles(try compatibleModelProfiles(from: data, provider: provider))
        }
    }

    /// OpenAI-compatible gateways are not consistent about the envelope:
    /// most use `data`, while several hosted/local servers use `models`,
    /// `results`, or return the array directly. Accept all of those shapes so
    /// a working key is not mistaken for an empty catalog.
    static func compatibleModelProfiles(
        from data: Data,
        provider: LLMProvider
    ) throws -> [RemoteModelProfile] {
        let json = try JSONSerialization.jsonObject(with: data)
        let entries: [[String: Any]]
        if let array = json as? [[String: Any]] {
            entries = array
        } else if let object = json as? [String: Any] {
            let keys = ["data", "models", "results"]
            entries = keys.lazy.compactMap { object[$0] as? [[String: Any]] }.first ?? []
        } else {
            entries = []
        }

        return entries.compactMap { entry in
            let id = (entry["id"] as? String)
                ?? (entry["model"] as? String)
                ?? (entry["name"] as? String)
            guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let displayName = (entry["name"] as? String) ?? (entry["display_name"] as? String)
            let efforts = reasoningEfforts(from: entry)
            let defaultEffort = (entry["default_reasoning_effort"] as? String)
                ?? (entry["defaultReasoningEffort"] as? String)
            return RemoteModelProfile(
                provider: provider,
                model: id,
                displayName: displayName,
                supportsReasoning: efforts.isEmpty ? nil : true,
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: defaultEffort)
        }
    }

    private static func reasoningEfforts(from entry: [String: Any]) -> [String] {
        let keys = [
            "supported_reasoning_efforts", "supportedReasoningEfforts",
            "reasoning_efforts", "reasoningEfforts",
        ]
        for key in keys {
            if let values = entry[key] as? [String] {
                return values
            }
            if let values = entry[key] as? [[String: Any]] {
                let strings = values.compactMap {
                    ($0["reasoning_effort"] as? String) ?? ($0["reasoningEffort"] as? String)
                }
                if !strings.isEmpty { return strings }
            }
        }
        return []
    }

    private static func deduplicatedProfiles(_ profiles: [RemoteModelProfile]) -> [RemoteModelProfile] {
        var byID: [String: RemoteModelProfile] = [:]
        for profile in profiles { byID[profile.model] = profile }
        return byID.values.sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
    }

    /// Models returned by Gemini include capability metadata. Filtering on
    /// the name (the previous implementation required the literal word
    /// "gemini") drops valid aliases and future model families; the API's
    /// `supportedGenerationMethods` field is the contract we actually need.
    static func geminiModelID(from entry: GeminiModelEntry) -> String? {
        guard let name = entry.name else { return nil }
        let short = normalizedGeminiModelID(name)
        guard !short.isEmpty,
              entry.supportedGenerationMethods.contains("generateContent")
        else { return nil }
        return short
    }

    /// The model catalog returns `models/foo`, while users often paste that
    /// fully-qualified value into Settings. The REST path already supplies
    /// the `models/` segment, so normalize both forms before sending.
    static func normalizedGeminiModelID(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("models/")
            ? String(trimmed.dropFirst("models/".count))
            : trimmed
    }

    struct GeminiModelEntry: Codable, Sendable {
        var name: String?
        var displayName: String?
        var description: String?
        var inputTokenLimit: Int?
        var outputTokenLimit: Int?
        var supportedGenerationMethods: [String] = []
        var supportsVision: Bool?
    }

    private struct GeminiModels: Codable, Sendable {
        var models: [GeminiModelEntry] = []
        var nextPageToken: String?
    }

    private struct AnthropicModels: Codable, Sendable {
        struct Model: Codable, Sendable { var id: String? }
        var data: [Model] = []
    }

    private static func get(
        _ request: URLRequest,
        provider: LLMProvider,
        session: URLSession = .shared
    ) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteLLMError.transport("non-HTTP response from \(provider.displayName)")
            }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(decoding: data, as: UTF8.self)
                let detail = errorDetail(from: text) ?? String(text.prefix(300))
                throw RemoteLLMError.badStatus(http.statusCode, detail)
            }
            return data
        } catch is CancellationError {
            throw RemoteLLMError.cancelled
        } catch let error as RemoteLLMError {
            throw error
        } catch {
            throw RemoteLLMError.transport("\(provider.displayName): \(error.localizedDescription)")
        }
    }

    // MARK: Wire types (non-streaming test responses)

    struct OpenAICompletion: Codable, Sendable {
        struct Choice: Codable, Sendable {
            struct Message: Codable, Sendable {
                var content: String?
            }
            var message: Message?
        }
        var model: String?
        var choices: [Choice]?
        var error: OpenAIErrorBody?
    }

    struct GeminiCompletion: Codable, Sendable {
        var candidates: [GeminiChunk.Candidate]?
        var error: GeminiErrorBody?
    }

    // MARK: SSE parsing

    /// One parsed SSE line's outcome.
    enum SSELineAction: Equatable {
        case none
        case done
        case text(String)
        case textAndUsage(String, UsageInfo)
        case usage(UsageInfo)
        case toolFragment(index: Int, name: String?, arguments: String?)
        case textAndToolFragment(
            text: String,
            index: Int,
            name: String?,
            arguments: String?)
    }

    /// Token usage reported by the provider (OpenAI `usage` with
    /// `stream_options`, Gemini `usageMetadata`, Anthropic `usage`).
    struct UsageInfo: Sendable, Equatable {
        public var promptTokens: Int?
        public var completionTokens: Int?
    }

    /// Processes ONE complete SSE line (raw bytes, no newline). Pure — the
    /// byte-level split guarantees the line is complete UTF-8: newline bytes
    /// (0x0A/0x0D) cannot appear inside a multi-byte UTF-8 sequence, so
    /// splitting on them never cuts a character.
    static func processSSELine(_ line: [UInt8]) -> SSELineAction {
        // Only `data:` lines carry payloads; comments/`event:`/`id:` are
        // ignored (Anthropic's `event:` names need no special handling —
        // the JSON `type` field inside the payload is sufficient).
        guard line.count > 5,
              line[0] == 0x64, line[1] == 0x61, line[2] == 0x74, line[3] == 0x61, line[4] == 0x3A
        else { return .none }
        var payload = line[5...]
        while let f = payload.first, f == 0x20 { payload = payload.dropFirst() }
        while let l = payload.last, l == 0x20 { payload = payload.dropLast() }
        guard !payload.isEmpty else { return .none }
        if payload.elementsEqual([0x5B, 0x44, 0x4F, 0x4E, 0x45, 0x5D]) { return .done }  // "[DONE]"
        guard let data = Data(payload) as Data?,
              let extracted = extract(from: data)
        else { return .none }
        if let fragment = extracted.tool {
            if let text = extracted.text, !text.isEmpty {
                return .textAndToolFragment(
                    text: text,
                    index: fragment.index,
                    name: fragment.name,
                    arguments: fragment.arguments)
            }
            return .toolFragment(index: fragment.index, name: fragment.name, arguments: fragment.arguments)
        }
        if let text = extracted.text, !text.isEmpty {
            if let usage = extracted.usage { return .textAndUsage(text, usage) }
            return .text(text)
        }
        if let usage = extracted.usage { return .usage(usage) }
        return .none
    }

    private final class SSEActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()

        func touch() {
            lock.lock()
            last = Date()
            lock.unlock()
        }

        var idle: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(last)
        }
    }

    /// Consumes an SSE byte stream, decoding data: {json} lines into text
    /// deltas. Lines are split at the BYTE level and decoded only when
    /// complete — per-byte String decoding (the old code) corrupted every
    /// multi-byte character that straddled a read boundary. Tolerant of
    /// CRLF and keep-alive comments. An inactivity watchdog fails the stream
    /// when the connection goes silent (a stalled proxy otherwise hangs the
    /// agent forever — `timeoutInterval` only bounds the first byte).
    static func consumeSSE(
        bytes: some AsyncSequence<UInt8, any Error>,
        inactivityTimeout: TimeInterval = 90,
        onText: @escaping @Sendable (String) -> Void,
        onUsage: (@Sendable (UsageInfo) -> Void)? = nil
    ) async throws {
        let clock = SSEActivity()
        let source = SSEByteBox(bytes)
        let text = onText
        let usage = onUsage
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await source.consume(
                    clock: clock, onText: text, onUsage: usage)
            }
            group.addTask {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        if clock.idle > inactivityTimeout {
                            throw RemoteLLMError.transport(
                                "stream stalled — no data for \(Int(inactivityTimeout))s")
                        }
                    }
                } catch is CancellationError {
                    return
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private final class SSEByteBox<S: AsyncSequence>: @unchecked Sendable
    where S.Element == UInt8, S.Failure == any Error {
        let sequence: S
        init(_ sequence: S) { self.sequence = sequence }

        func consume(
            clock: SSEActivity,
            onText: @escaping @Sendable (String) -> Void,
            onUsage: (@Sendable (UsageInfo) -> Void)?
        ) async throws {
            try await RemoteLLMClient.consumeSSELocked(
                bytes: sequence, clock: clock, onText: onText, onUsage: onUsage)
        }
    }

    private static func consumeSSELocked(
        bytes: some AsyncSequence<UInt8, any Error>,
        clock: SSEActivity,
        onText: @escaping @Sendable (String) -> Void,
        onUsage: (@Sendable (UsageInfo) -> Void)?
    ) async throws {
        var line: [UInt8] = []
        var done = false
        var toolAcc: [Int: (name: String, arguments: String)] = [:]
        for try await byte in bytes {
            clock.touch()
            if byte == 0x0A || byte == 0x0D {
                if !line.isEmpty {
                    switch processSSELine(line) {
                    case .done: done = true
                    case .text(let text): if !done { onText(text) }
                    case .textAndUsage(let text, let usage):
                        if !done {
                            onText(text)
                            onUsage?(usage)
                        }
                    case .usage(let usage): if !done { onUsage?(usage) }
                    case .toolFragment(let index, let name, let arguments):
                        if !done {
                            var current = toolAcc[index] ?? ("", "")
                            if let name, !name.isEmpty { current.name = name }
                            if let arguments { current.arguments += arguments }
                            toolAcc[index] = current
                        }
                    case .textAndToolFragment(let text, let index, let name, let arguments):
                        if !done {
                            onText(text)
                            var current = toolAcc[index] ?? ("", "")
                            if let name, !name.isEmpty { current.name = name }
                            if let arguments { current.arguments += arguments }
                            toolAcc[index] = current
                        }
                    case .none: break
                    }
                    line.removeAll(keepingCapacity: true)
                }
            } else if !done {
                line.append(byte)
            }
        }
        if !line.isEmpty, !done {
            switch processSSELine(line) {
            case .done: break
            case .text(let text): onText(text)
            case .textAndUsage(let text, let usage):
                onText(text)
                onUsage?(usage)
            case .usage(let usage): onUsage?(usage)
            case .toolFragment(let index, let name, let arguments):
                var current = toolAcc[index] ?? ("", "")
                if let name, !name.isEmpty { current.name = name }
                if let arguments { current.arguments += arguments }
                toolAcc[index] = current
            case .textAndToolFragment(let text, let index, let name, let arguments):
                onText(text)
                var current = toolAcc[index] ?? ("", "")
                if let name, !name.isEmpty { current.name = name }
                if let arguments { current.arguments += arguments }
                toolAcc[index] = current
            case .none: break
            }
        }
        if let fence = NativeToolBridge.serializeAccumulated(toolAcc) {
            onText(fence)
        }
    }

    struct Extracted: Sendable {
        var text: String?
        var usage: UsageInfo?
        var tool: ToolFragment?
        struct ToolFragment: Sendable {
            var index: Int
            var name: String?
            var arguments: String?
        }
    }

    /// Extracts the content delta (and any usage report) from an OpenAI,
    /// Gemini, or Anthropic chunk. Each wire format is tried only when the
    /// JSON actually looks like it — an all-optional struct otherwise
    /// "matches" every payload and swallows the other providers' chunks.
    static func extract(from data: Data) -> Extracted? {
        // Cheap structural sniff: which provider's top-level keys are present?
        let topLevel: [String: Any] = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let looksOpenAI = topLevel["choices"] != nil || topLevel["usage"] != nil || topLevel["object"] != nil
        let looksGemini = topLevel["candidates"] != nil || topLevel["usageMetadata"] != nil
        let looksAnthropic = topLevel["type"] != nil

        if let responseType = topLevel["type"] as? String,
           responseType.hasPrefix("response.") {
            return extractResponses(from: topLevel)
        }

        if looksOpenAI, let chunk = try? JSONDecoder().decode(OpenAIChunk.self, from: data) {
            var usage: UsageInfo?
            if let u = chunk.usage {
                usage = UsageInfo(promptTokens: u.prompt_tokens,
                                  completionTokens: u.completion_tokens)
            }
            if let delta = chunk.choices?.first?.delta {
                var textParts: [String] = []
                if let reasoning = openAIReasoningText(in: topLevel)
                    ?? delta.reasoning_content
                    ?? delta.reasoning,
                   !reasoning.isEmpty {
                    textParts.append("<think>\(reasoning)</think>")
                }
                if let content = delta.content, !content.isEmpty {
                    textParts.append(content)
                }
                let tool = delta.tool_calls?.first.map { call in
                    Extracted.ToolFragment(
                        index: call.index ?? 0,
                        name: call.function?.name,
                        arguments: call.function?.arguments)
                }
                if !textParts.isEmpty || tool != nil {
                    return Extracted(
                        text: textParts.isEmpty ? nil : textParts.joined(),
                        usage: usage,
                        tool: tool)
                }
            }
            if usage != nil { return Extracted(usage: usage) }
            return nil
        }
        if looksGemini, let gemini = try? JSONDecoder().decode(GeminiChunk.self, from: data) {
            var usage: UsageInfo?
            if let m = gemini.usageMetadata {
                usage = UsageInfo(promptTokens: m.promptTokenCount,
                                  completionTokens: m.candidatesTokenCount)
            }
            let parts = gemini.candidates?.first?.content?.parts ?? []
            var textParts: [String] = []
            var tool: Extracted.ToolFragment?
            for (index, part) in parts.enumerated() {
                if tool == nil, let functionCall = part.functionCall,
                   let name = functionCall.name, !name.isEmpty {
                    let arguments: String
                    if let args = functionCall.args,
                       let encoded = try? JSONEncoder().encode(args) {
                        arguments = String(decoding: encoded, as: UTF8.self)
                    } else {
                        arguments = "{}"
                    }
                    tool = .init(index: index, name: name, arguments: arguments)
                }
                guard let text = part.text, !text.isEmpty else { continue }
                textParts.append(part.thought == true ? "<think>\(text)</think>" : text)
            }
            let text = textParts.joined()
            if !text.isEmpty || tool != nil {
                return Extracted(
                    text: text.isEmpty ? nil : text,
                    usage: usage,
                    tool: tool)
            }
            if usage != nil { return Extracted(usage: usage) }
            return nil
        }
        if looksAnthropic, let anthropic = try? JSONDecoder().decode(AnthropicChunk.self, from: data) {
            var usage: UsageInfo?
            if let u = anthropic.usage {
                usage = UsageInfo(promptTokens: u.input_tokens, completionTokens: u.output_tokens)
            }
            if let m = anthropic.message?.usage {
                usage = UsageInfo(promptTokens: m.input_tokens, completionTokens: m.output_tokens)
            }
            if anthropic.type == "content_block_start",
               anthropic.content_block?.type == "tool_use" {
                return Extracted(
                    usage: usage,
                    tool: .init(
                        index: anthropic.index ?? 0,
                        name: anthropic.content_block?.name,
                        arguments: nil))
            }
            if anthropic.type == "content_block_start",
               anthropic.content_block?.type == "thinking",
               let thinking = anthropic.content_block?.thinking,
               !thinking.isEmpty {
                return Extracted(text: "<think>\(thinking)</think>", usage: usage)
            }
            if anthropic.type == "content_block_delta", let delta = anthropic.delta {
                if delta.type == "input_json_delta", let json = delta.partial_json {
                    return Extracted(
                        usage: usage,
                        tool: .init(index: anthropic.index ?? 0, name: nil, arguments: json))
                }
                if delta.type == "thinking_delta", let t = delta.thinking, !t.isEmpty {
                    return Extracted(text: "<think>\(t)</think>", usage: usage)
                }
                if delta.type == "text_delta", let t = delta.text {
                    return Extracted(text: t, usage: usage)
                }
            }
            if usage != nil { return Extracted(usage: usage) }
            return nil
        }
        return nil
    }

    private static func extractResponses(from object: [String: Any]) -> Extracted? {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String, !delta.isEmpty else { return nil }
            return Extracted(text: delta, usage: nil, tool: nil)
        case "response.function_call_arguments.delta":
            guard let delta = object["delta"] as? String else { return nil }
            let index = (object["output_index"] as? Int) ?? 0
            return Extracted(
                text: nil,
                usage: nil,
                tool: .init(index: index, name: nil, arguments: delta))
        case "response.output_item.added":
            guard let item = object["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call"
            else { return nil }
            let index = (object["output_index"] as? Int) ?? 0
            return Extracted(
                text: nil,
                usage: nil,
                tool: .init(index: index, name: item["name"] as? String, arguments: nil))
        case "response.completed", "response.done":
            guard let response = object["response"] as? [String: Any],
                  let usage = response["usage"] as? [String: Any]
            else { return nil }
            let prompt = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int)
            let completion = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int)
            guard prompt != nil || completion != nil else { return nil }
            return Extracted(
                text: nil,
                usage: UsageInfo(promptTokens: prompt, completionTokens: completion),
                tool: nil)
        default:
            return nil
        }
    }

    /// OpenAI-compatible reasoning is not standardized. OpenRouter and
    /// several local gateways expose `reasoning_details` while DeepSeek and
    /// llama.cpp commonly use `reasoning_content`. Read the loose JSON keys
    /// in addition to the typed fields above so a new provider shape cannot
    /// make the entire chunk fail decoding and silently erase the reasoning
    /// channel.
    private static func openAIReasoningText(in topLevel: [String: Any]) -> String? {
        var values: [String] = []

        func append(_ value: Any?) {
            guard let text = value as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            values.append(text)
        }

        if let choices = topLevel["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any]
        {
            for key in ["reasoning_content", "reasoning", "thinking", "analysis", "thought"] {
                append(delta[key])
            }
            if let details = delta["reasoning_details"] as? [Any] {
                for detail in details {
                    guard let object = detail as? [String: Any] else { continue }
                    append(object["text"])
                    append(object["summary"])
                    append(object["content"])
                }
            }
        }

        // A few proxy gateways lift reasoning to the chunk root.
        for key in ["reasoning_content", "reasoning", "thinking", "analysis", "thought"] {
            append(topLevel[key])
        }

        guard !values.isEmpty else { return nil }
        return values.joined()
    }

    /// Backwards-compatible text-only shim (existing tests + callers).
    static func extractText(from data: Data) -> String? {
        extract(from: data)?.text
    }
}
