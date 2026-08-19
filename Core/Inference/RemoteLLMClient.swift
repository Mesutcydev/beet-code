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

    struct OpenAIRequest: Codable, Sendable {
        var model: String
        var messages: [OpenAIMessage]
        var temperature: Double?
        var max_tokens: Int?
        /// o-series / gpt-5-era models reject `max_tokens`; when the model
        /// looks like a reasoning model the caller sets this instead.
        var max_completion_tokens: Int?
        var stream: Bool = true
        /// Asks OpenAI-compatible servers for a final usage chunk — powers
        /// truthful token stats instead of chunk counting.
        var stream_options: StreamOptions?
        struct StreamOptions: Codable, Sendable {
            var include_usage: Bool = true
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
        }
        struct GenerationConfig: Codable, Sendable {
            var temperature: Double?
            var maxOutputTokens: Int?
        }
        var contents: [Content]
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

    struct AnthropicRequest: Codable, Sendable {
        var model: String
        var max_tokens: Int  // mandatory on Anthropic
        var system: String?
        var messages: [AnthropicMessage]
        var temperature: Double?
        var stream: Bool = true
    }

    struct AnthropicChunk: Codable, Sendable {
        struct Delta: Codable, Sendable {
            var type: String?
            var text: String?
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
        var usage: Usage?
        var message: MessageInfo?
        var error: OpenAIErrorBody?
    }

    // MARK: Public API

    static let userAgent = "BeetCode/0.5 (macOS coding agent)"

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
        return m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.hasPrefix("gpt-5")
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
    static func streamOpenAICompatible(
        provider: LLMProvider,
        baseURL: URL,
        apiKey: String,
        model: String,
        turns: [ChatTurn],
        temperature: Double?,
        maxTokens: Int?,
        onUsage: (@Sendable (UsageInfo) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let first = streamOpenAIOnce(
                        provider: provider, baseURL: baseURL, apiKey: apiKey,
                        model: model, turns: turns, temperature: temperature,
                        maxTokens: maxTokens, includeStreamOptions: true, onUsage: onUsage)
                    for try await chunk in first {
                        if Task.isCancelled { throw RemoteLLMError.cancelled }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch RemoteLLMError.badStatus(let code, _) where code == 400 {
                    // Compatibility fallback: strict OpenAI-compatible
                    // servers (older vLLM/llama.cpp builds, some proxies)
                    // reject the unknown `stream_options` field with a 400
                    // before any content streams. Retry once without it;
                    // usage stats degrade to chunk counting.
                    do {
                        let retry = streamOpenAIOnce(
                            provider: provider, baseURL: baseURL, apiKey: apiKey,
                            model: model, turns: turns, temperature: temperature,
                            maxTokens: maxTokens, includeStreamOptions: false, onUsage: onUsage)
                        for try await chunk in retry {
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
        includeStreamOptions: Bool,
        onUsage: (@Sendable (UsageInfo) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let messages = prepareOpenAIMessages(turns)
            let reasoningCap = usesMaxCompletionTokens(model)
            let body = OpenAIRequest(
                model: model,
                messages: messages,
                temperature: omitsTemperature(model) ? nil : temperature,
                max_tokens: reasoningCap ? nil : maxTokens,
                max_completion_tokens: reasoningCap ? maxTokens : nil,
                stream: true,
                stream_options: includeStreamOptions ? .init() : nil)
            runStreamingRequest(makeRequest: {
                var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        onUsage: (@Sendable (UsageInfo) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let (system, contents) = prepareGeminiPayload(turns)
            let url = baseURL
                .appendingPathComponent("models/\(model):streamGenerateContent")
                .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])
            let body = GeminiRequest(
                contents: contents,
                systemInstruction: system.map { .init(role: "user", parts: [.init(text: $0)]) },
                generationConfig: .init(
                    temperature: temperature,
                    maxOutputTokens: maxTokens))
            runStreamingRequest(makeRequest: {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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
                stream: true)
            runStreamingRequest(makeRequest: {
                var request = URLRequest(url: baseURL.appendingPathComponent("messages"))
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 120
                request.httpBody = try JSONEncoder().encode(body)
                return request
            }, continuation: continuation, onUsage: onUsage)
        }
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
            let url = base.appendingPathComponent("models/\(model):generateContent")
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
        guard http.statusCode == 200 else {
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

    struct ModelListResponse: Codable, Sendable {
        struct Entry: Codable, Sendable {
            var id: String
        }
        var data: [Entry]?
    }

    /// Fetches the provider's live model catalog (`GET /v1/models` for
    /// OpenAI-compatible, native list for Gemini). Returns an empty list on
    /// any failure — callers fall back to the static presets.
    static func fetchModels(provider: LLMProvider, apiKey: String?) async -> [String] {
        switch provider {
        case .gemini:
            guard let base = provider.geminiBaseURL else { return [] }
            var request = URLRequest(url: base.appendingPathComponent("models")
                .appending(queryItems: [URLQueryItem(name: "pageSize", value: "200")]))
            request.timeoutInterval = 15
            if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key") }
            struct GeminiModels: Codable {
                struct Model: Codable { var name: String? }
                var models: [Model]?
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(GeminiModels.self, from: data)
            else { return [] }
            // Strip the "models/" prefix; keep only generateContent-capable
            // chat models (AQA/embedding-only models are useless here).
            return decoded.models?.compactMap { entry -> String? in
                guard let name = entry.name else { return nil }
                let short = name.replacingOccurrences(of: "models/", with: "")
                let m = short.lowercased()
                guard m.contains("gemini") else { return nil }
                if m.contains("embedding") || m.contains("aqa") { return nil }
                return short
            } ?? []
        case .anthropic:
            guard let base = provider.anthropicBaseURL else { return [] }
            var request = URLRequest(url: base.appendingPathComponent("models")
                .appending(queryItems: [URLQueryItem(name: "limit", value: "100")]))
            request.timeoutInterval = 15
            if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            struct AnthropicModels: Codable {
                struct Model: Codable { var id: String? }
                var data: [Model]?
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(AnthropicModels.self, from: data)
            else { return [] }
            return decoded.data?.compactMap(\.id) ?? []
        default:
            guard let base = provider.openAICompatibleBaseURL else { return [] }
            var request = URLRequest(url: base.appendingPathComponent("models"))
            request.timeoutInterval = 15
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            if provider == .openRouter {
                request.setValue("Beet Code", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("Beet Code", forHTTPHeaderField: "X-Title")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(ModelListResponse.self, from: data)
            else { return [] }
            return decoded.data?.map(\.id) ?? []
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
        case usage(UsageInfo)
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
        if let usage = extracted.usage { return .usage(usage) }
        if let text = extracted.text, !text.isEmpty { return .text(text) }
        return .none
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
        var line: [UInt8] = []
        var lastActivity = Date()
        var sinceCheck = 0
        var done = false
        for try await byte in bytes {
            lastActivity = Date()
            if byte == 0x0A || byte == 0x0D {
                if !line.isEmpty {
                    switch processSSELine(line) {
                    case .done: done = true
                    case .text(let text): if !done { onText(text) }
                    case .usage(let usage): if !done { onUsage?(usage) }
                    case .none: break
                    }
                    line.removeAll(keepingCapacity: true)
                }
            } else if !done {
                line.append(byte)
            }
            // Watchdog: check at most every 4 KB to keep Date() cheap.
            sinceCheck += 1
            if sinceCheck >= 4096 {
                sinceCheck = 0
                if Date().timeIntervalSince(lastActivity) > inactivityTimeout {
                    throw RemoteLLMError.transport(
                        "stream stalled — no data for \(Int(inactivityTimeout))s")
                }
            }
        }
        if !line.isEmpty, !done {
            switch processSSELine(line) {
            case .done: break
            case .text(let text): onText(text)
            case .usage(let usage): onUsage?(usage)
            case .none: break
            }
        }
    }

    /// Extracts the content delta (and any usage report) from an OpenAI,
    /// Gemini, or Anthropic chunk. Each wire format is tried only when the
    /// JSON actually looks like it — an all-optional struct otherwise
    /// "matches" every payload and swallows the other providers' chunks.
    static func extract(from data: Data) -> (text: String?, usage: UsageInfo?)? {
        // Cheap structural sniff: which provider's top-level keys are present?
        let topLevel: [String: Any] = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let looksOpenAI = topLevel["choices"] != nil || topLevel["usage"] != nil || topLevel["object"] != nil
        let looksGemini = topLevel["candidates"] != nil || topLevel["usageMetadata"] != nil
        let looksAnthropic = topLevel["type"] != nil

        if looksOpenAI, let chunk = try? JSONDecoder().decode(OpenAIChunk.self, from: data) {
            var usage: UsageInfo?
            if let u = chunk.usage {
                usage = UsageInfo(promptTokens: u.prompt_tokens,
                                  completionTokens: u.completion_tokens)
            }
            if let delta = chunk.choices?.first?.delta {
                // Reasoning tokens are folded into think blocks so the loop's
                // reasoning toggle handles every provider uniformly.
                if let reasoning = delta.reasoning_content ?? delta.reasoning,
                   !reasoning.isEmpty {
                    return ("<think>\(reasoning)</think>", usage)
                }
                if let content = delta.content { return (content, usage) }
            }
            if usage != nil { return (nil, usage) }
            return nil
        }
        if looksGemini, let gemini = try? JSONDecoder().decode(GeminiChunk.self, from: data) {
            var usage: UsageInfo?
            if let m = gemini.usageMetadata {
                usage = UsageInfo(promptTokens: m.promptTokenCount,
                                  completionTokens: m.candidatesTokenCount)
            }
            if let text = gemini.candidates?.first?.content?.parts?.compactMap(\.text).joined() {
                return (text, usage)
            }
            if usage != nil { return (nil, usage) }
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
            if anthropic.type == "content_block_delta", let delta = anthropic.delta {
                if delta.type == "thinking_delta", let t = delta.thinking, !t.isEmpty {
                    return ("<think>\(t)</think>", usage)
                }
                if delta.type == "text_delta", let t = delta.text { return (t, usage) }
            }
            if usage != nil { return (nil, usage) }
            return nil
        }
        return nil
    }

    /// Backwards-compatible text-only shim (existing tests + callers).
    static func extractText(from data: Data) -> String? {
        extract(from: data)?.text
    }
}