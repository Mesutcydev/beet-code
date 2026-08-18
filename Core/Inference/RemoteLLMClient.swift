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
        var stream: Bool = true
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
    }

    struct GeminiErrorBody: Codable, Sendable {
        struct Status: Codable, Sendable {
            var message: String?
        }
        var status: Status?
        var message: String?
    }

    // MARK: Public API

    /// Streams a chat completion from an OpenAI-compatible endpoint.
    /// Yields content deltas; finish without error = completion.
    static func streamOpenAICompatible(
        provider: LLMProvider,
        baseURL: URL,
        apiKey: String,
        model: String,
        messages: [OpenAIMessage],
        temperature: Double?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            // OpenRouter wants its app identity header for free-tier usage.
            if provider == .openRouter {
                request.setValue("Beet Code", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("Beet Code", forHTTPHeaderField: "X-Title")
            }
            let body = OpenAIRequest(
                model: model,
                messages: messages,
                temperature: temperature,
                max_tokens: maxTokens)
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let task = Task { try await URLSession.shared.bytes(for: request) }
            continuation.onTermination = { _ in task.cancel() }
            Task {
                do {
                    let (bytes, response) = try await task.value
                    guard let http = response as? HTTPURLResponse else {
                        throw RemoteLLMError.transport("non-HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await chunk in bytes { body += String(decoding: [chunk], as: UTF8.self) }
                        throw RemoteLLMError.badStatus(http.statusCode, body)
                    }
                    try await Self.consumeSSE(bytes: bytes) { text in
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: RemoteLLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Streams a chat completion from Gemini's native API.
    static func streamGemini(
        baseURL: URL,
        apiKey: String,
        model: String,
        messages: [OpenAIMessage],
        temperature: Double?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            // Gemini roles are user/model; system content is folded into the
            // first user turn as a prefix.
            var contents: [GeminiRequest.Content] = []
            var systemText = ""
            for message in messages {
                switch message.role {
                case "system":
                    systemText += message.content + "\n"
                case "assistant":
                    contents.append(.init(role: "model", parts: [.init(text: message.content)]))
                default:
                    contents.append(.init(role: "user", parts: [.init(text: message.content)]))
                }
            }
            if !systemText.isEmpty {
                if var first = contents.first, first.role == "user" {
                    first.parts.insert(.init(text: systemText), at: 0)
                    contents[0] = first
                } else {
                    contents.insert(.init(role: "user", parts: [.init(text: systemText)]), at: 0)
                }
            }

            let url = baseURL
                .appendingPathComponent("models/\(model):streamGenerateContent")
                .appending(queryItems: [
                    URLQueryItem(name: "alt", value: "sse"),
                    URLQueryItem(name: "key", value: apiKey)])
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            let body = GeminiRequest(
                contents: contents,
                generationConfig: .init(
                    temperature: temperature,
                    maxOutputTokens: maxTokens))
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let task = Task { try await URLSession.shared.bytes(for: request) }
            continuation.onTermination = { _ in task.cancel() }
            Task {
                do {
                    let (bytes, response) = try await task.value
                    guard let http = response as? HTTPURLResponse else {
                        throw RemoteLLMError.transport("non-HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await chunk in bytes { body += String(decoding: [chunk], as: UTF8.self) }
                        throw RemoteLLMError.badStatus(http.statusCode, body)
                    }
                    try await Self.consumeSSE(bytes: bytes) { text in
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: RemoteLLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Non-streaming connectivity probe used by the Settings "Test" button.
    /// Sends a tiny completion request and returns the model id the provider
    /// answered with. Throws `RemoteLLMError` with the provider's message on
    /// any failure (bad key, unknown model, transport).
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
            let url = base
                .appendingPathComponent("models/\(model):generateContent")
                .appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.timeoutInterval = 30
            let body = GeminiRequest(
                contents: [.init(role: "user", parts: [.init(text: "ping")])],
                generationConfig: .init(temperature: 0, maxOutputTokens: 4))
            bodyData = try JSONEncoder().encode(body)
            r.httpBody = bodyData
            request = r
        default:
            guard let base = provider.openAICompatibleBaseURL else {
                throw RemoteLLMError.invalidConfiguration("no endpoint URL")
            }
            var r = URLRequest(url: base.appendingPathComponent("chat/completions"))
            r.httpMethod = "POST"
            r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.timeoutInterval = 30
            if provider == .openRouter {
                r.setValue("Beet Code", forHTTPHeaderField: "HTTP-Referer")
                r.setValue("Beet Code", forHTTPHeaderField: "X-Title")
            }
            let body = OpenAIRequest(
                model: model,
                messages: [.init(role: "user", content: "ping")],
                temperature: 0,
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
            let detail = (try? JSONDecoder().decode(OpenAIChunk.self, from: data))?.error?.message
                ?? String(text.prefix(220))
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

    /// Consumes an SSE byte stream, decoding data: {json} lines into text
    /// deltas. Tolerant of CRLF, multi-line data, and keep-alive comments.
    static func consumeSSE(
        bytes: URLSession.AsyncBytes,
        onText: @escaping @Sendable (String) -> Void
    ) async throws {
        var buffer = ""
        for try await chunk in bytes {
            buffer += String(decoding: [chunk], as: UTF8.self)
            // Process complete lines, keeping the remainder.
            while let newline = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.hasPrefix("data:") {
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { return }
                    guard let data = payload.data(using: .utf8) else { continue }
                    if let text = try? extractText(from: data) {
                        onText(text)
                    }
                }
            }
        }
    }

    /// Extracts the content delta from an OpenAI or Gemini chunk.
    static func extractText(from data: Data) -> String? {
        if let chunk = try? JSONDecoder().decode(OpenAIChunk.self, from: data),
           let delta = chunk.choices?.first?.delta {
            // Reasoning tokens are folded into think blocks so the loop's
            // reasoning toggle handles every provider uniformly.
            if let reasoning = delta.reasoning_content ?? delta.reasoning,
               !reasoning.isEmpty {
                return "<think>\(reasoning)</think>"
            }
            return delta.content
        }
        if let gemini = try? JSONDecoder().decode(GeminiChunk.self, from: data),
           let text = gemini.candidates?.first?.content?.parts?.compactMap(\.text).joined() {
            return text
        }
        return nil
    }
}