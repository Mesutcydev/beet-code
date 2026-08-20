import Foundation

/// OpenAI-compatible request/response surface for the local API server.
/// Stateless by contract: every `/v1/chat/completions` request carries the
/// full conversation, so the engine session is reset and replayed per
/// request. This matches how LM Studio exposes local models and how Codex /
/// Claude Code / Aider drive an OpenAI-compatible endpoint.
public enum OpenAIRoutes {

    /// Dispatch a request to a route. Falls back to the injected resolver for
    /// app/CLI-provided routes, then to a 404.
    public static func route(
        _ request: LocalAPIServer.Request,
        engine: any LLMEngine,
        resolver: LocalAPIServer.RouteResolver,
        includeStandardRoutes: Bool = true
    ) async -> LocalAPIServer.RouteResult {
        // Custom surfaces get first refusal. A network-facing server can opt
        // out of the standard inference routes entirely, which keeps a
        // session-control listener from exposing the model API by accident.
        if let custom = await resolver(request) {
            return custom
        }
        // OPTIONS preflight for CORS. Let a custom surface validate or reject
        // its own origin before this generic local-API response is returned.
        if request.method == "OPTIONS" {
            return .response(LocalAPIServer.Response(status: 204, contentType: "text/plain"))
        }
        guard includeStandardRoutes else {
            return .response(.json(
                errorJSON(message: "Unknown endpoint: \(request.method) \(request.path)", type: "invalid_request_error"),
                status: 404))
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"), ("GET", "/models"):
            return .response(await modelsResponse(engine: engine))

        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            return await chatCompletions(request, engine: engine)

        case ("POST", "/v1/messages"):
            return await anthropicMessages(request, engine: engine)

        case ("GET", "/health"), ("GET", "/healthz"):
            return .response(await healthResponse(engine: engine))

        case ("GET", "/"):
            return .response(.text(
                "Beet Code API server — OpenAI-compatible local inference.\n" +
                "  GET  /v1/models\n" +
                "  POST /v1/chat/completions\n" +
                "  POST /v1/messages      (Anthropic-format)\n" +
                "  GET  /health\n"))

        default:
            return .response(.json(
                errorJSON(message: "Unknown endpoint: \(request.method) \(request.path)", type: "invalid_request_error"),
                status: 404))
        }
    }

    // MARK: /v1/models

    static func modelsResponse(engine: any LLMEngine) async -> LocalAPIServer.Response {
        let loaded = await engine.loadedModelID
        let id = loaded ?? "beetcode"
        let model = LFJSONValue.object([
            "id": .string(id),
            "object": .string("model"),
            "created": .number(Double(Int(Date().timeIntervalSince1970))),
            "owned_by": .string("beetcode"),
            // Signal whether the model is actually resident: clients can use
            // this to decide between "load then chat" vs "chat directly".
            "loaded": .bool(loaded != nil),
        ])
        return .json(LFJSONValue.object([
            "object": .string("list"),
            "data": .array([model]),
        ]))
    }

    // MARK: /health

    static func healthResponse(engine: any LLMEngine) async -> LocalAPIServer.Response {
        let loaded = await engine.loadedModelID
        let stats = await engine.stats
        var object: [String: LFJSONValue] = [
            "status": .string("ok"),
            "model_loaded": .bool(loaded != nil),
        ]
        if let loaded { object["model"] = .string(loaded) }
        if let tps = stats.tokensPerSecond { object["tokens_per_second"] = .number(tps) }
        object["generated_tokens"] = .number(Double(stats.generatedTokens))
        return .json(LFJSONValue.object(object))
    }

    // MARK: /v1/chat/completions

    static func chatCompletions(
        _ request: LocalAPIServer.Request, engine: any LLMEngine
    ) async -> LocalAPIServer.RouteResult {
        guard let json = request.bodyJSON, let object = json.objectValue else {
            return .response(.json(
                errorJSON(message: "Request body must be a JSON object.", type: "invalid_request_error"),
                status: 400))
        }

        guard let messages = object["messages"]?.arrayValue, !messages.isEmpty else {
            return .response(.json(
                errorJSON(message: "'messages' is required and must be a non-empty array.", type: "invalid_request_error"),
                status: 400))
        }

        // Convert OpenAI messages → engine turns.
        var turns: [ChatTurn] = []
        for message in messages {
            guard let m = message.objectValue else { continue }
            let role = m["role"]?.stringValue ?? "user"
            let content = extractContent(m["content"])
            let chatRole: ChatTurn.Role
            switch role {
            case "system": chatRole = .system
            case "assistant": chatRole = .assistant
            case "tool": chatRole = .tool
            default: chatRole = .user
            }
            turns.append(ChatTurn(role: chatRole, content: content))
        }
        guard !turns.isEmpty else {
            return .response(.json(
                errorJSON(message: "No valid messages found.", type: "invalid_request_error"),
                status: 400))
        }

        let stream = object["stream"]?.boolValue ?? false
        let maxTokens = object["max_tokens"]?.intValue ?? object["max_completion_tokens"]?.intValue
        let temperature = object["temperature"]?.numberValue
        let requestedModel = object["model"]?.stringValue
        let completionID = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        let created = Int(Date().timeIntervalSince1970)
        let modelName = await Self.reportedModelID(engine: engine, requested: requestedModel)

        // The endpoint is stateless: reset the engine session and replay the
        // full conversation, so repeated calls never accumulate stale turns.
        await engine.reset()

        if stream {
            return .stream(
                LocalAPIServer.Response(status: 200, contentType: "text/event-stream"),
                lines: streamCompletion(
                    engine: engine, turns: turns, id: completionID, model: modelName,
                    created: created, maxTokens: maxTokens, temperature: temperature))
        } else {
            return .response(await nonStreamingCompletion(
                engine: engine, turns: turns, id: completionID, model: modelName,
                created: created, maxTokens: maxTokens, temperature: temperature))
        }
    }

    /// Resolve the model id to report: honor the client's requested name when
    /// present (Codex sends its own model string), else the loaded model.
    private static func reportedModelID(engine: any LLMEngine, requested: String?) async -> String {
        if let requested, !requested.isEmpty { return requested }
        if let loaded = await engine.loadedModelID { return loaded }
        return "beetcode"
    }

    /// OpenAI allows `content` to be a string or an array of content parts.
    /// Flatten both to plain text.
    private static func extractContent(_ value: LFJSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let text):
            return text
        case .array(let parts):
            return parts.compactMap { part -> String? in
                guard let object = part.objectValue else { return nil }
                // Only "text" parts carry usable content; ignore image_url etc.
                if object["type"]?.stringValue == "text" {
                    return object["text"]?.stringValue
                }
                return object["text"]?.stringValue
            }.joined(separator: "\n")
        case .null:
            return ""
        default:
            return value.encoded()
        }
    }

    // MARK: Non-streaming

    private static func nonStreamingCompletion(
        engine: any LLMEngine, turns: [ChatTurn], id: String, model: String,
        created: Int, maxTokens: Int?, temperature: Double?
    ) async -> LocalAPIServer.Response {
        var collected = ""
        do {
            let stream = engine.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
            for try await chunk in stream {
                collected += chunk
            }
        } catch {
            return .json(
                errorJSON(message: "Generation failed: \(error.localizedDescription)", type: "server_error"),
                status: 500)
        }
        let stats = await engine.stats
        var usage: [String: LFJSONValue] = [:]
        usage["generated_tokens"] = .number(Double(stats.generatedTokens))
        return .json(LFJSONValue.object([
            "id": .string(id),
            "object": .string("chat.completion"),
            "created": .number(Double(created)),
            "model": .string(model),
            "choices": .array([
                .object([
                    "index": .number(0),
                    "message": .object([
                        "role": .string("assistant"),
                        "content": .string(collected),
                    ]),
                    "finish_reason": .string("stop"),
                ]),
            ]),
            "usage": .object(usage),
        ]))
    }

    // MARK: Streaming (SSE)

    private static func streamCompletion(
        engine: any LLMEngine, turns: [ChatTurn], id: String, model: String,
        created: Int, maxTokens: Int?, temperature: Double?
    ) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                // Open the stream with an initial role delta.
                continuation.yield(sseFrame(chatDelta(
                    id: id, model: model, created: created,
                    delta: ["role": .string("assistant")], finishReason: nil)))

                var caughtError: String?
                do {
                    let stream = engine.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        if chunk.isEmpty { continue }
                        continuation.yield(sseFrame(chatDelta(
                            id: id, model: model, created: created,
                            delta: ["content": .string(chunk)], finishReason: nil)))
                    }
                } catch {
                    caughtError = error.localizedDescription
                }

                // Terminal frame carries finish_reason.
                continuation.yield(sseFrame(chatDelta(
                    id: id, model: model, created: created,
                    delta: [:], finishReason: caughtError == nil ? "stop" : "error")))
                continuation.yield(Data("data: [DONE]\n\n".utf8))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// One SSE chat-completion chunk as an LFJSONValue.
    private static func chatDelta(
        id: String, model: String, created: Int,
        delta: [String: LFJSONValue], finishReason: String?
    ) -> LFJSONValue {
        var choice: [String: LFJSONValue] = [
            "index": .number(0),
            "delta": .object(delta),
        ]
        choice["finish_reason"] = finishReason.map { .string($0) } ?? .null
        return LFJSONValue.object([
            "id": .string(id),
            "object": .string("chat.completion.chunk"),
            "created": .number(Double(created)),
            "model": .string(model),
            "choices": .array([.object(choice)]),
        ])
    }

    private static func sseFrame(_ value: LFJSONValue) -> Data {
        Data("data: \(value.encoded())\n\n".utf8)
    }

    // MARK: Anthropic-format /v1/messages

    /// Serves the Anthropic Messages API shape (used by Claude Code and
    /// friends) against the same engine. Stateless, same as the OpenAI route.
    static func anthropicMessages(
        _ request: LocalAPIServer.Request, engine: any LLMEngine
    ) async -> LocalAPIServer.RouteResult {
        guard let json = request.bodyJSON, let object = json.objectValue else {
            return .response(.json(anthropicError("Request body must be a JSON object.", type: "invalid_request_error"), status: 400))
        }
        guard let messages = object["messages"]?.arrayValue, !messages.isEmpty else {
            return .response(.json(anthropicError("'messages' is required and must be a non-empty array.", type: "invalid_request_error"), status: 400))
        }

        var turns: [ChatTurn] = []
        // Anthropic carries the system prompt top-level, not as a message.
        let system = extractContent(object["system"])
        if !system.isEmpty {
            turns.append(ChatTurn(role: .system, content: system))
        }
        for message in messages {
            guard let m = message.objectValue else { continue }
            let role = m["role"]?.stringValue ?? "user"
            let content = extractContent(m["content"])
            let chatRole: ChatTurn.Role
            switch role {
            case "assistant": chatRole = .assistant
            case "user": chatRole = .user
            default: chatRole = .user
            }
            turns.append(ChatTurn(role: chatRole, content: content))
        }
        guard !turns.isEmpty else {
            return .response(.json(anthropicError("No valid messages found.", type: "invalid_request_error"), status: 400))
        }

        let stream = object["stream"]?.boolValue ?? false
        let maxTokens = object["max_tokens"]?.intValue
        let requestedModel = object["model"]?.stringValue
        let messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        let modelName = await reportedModelID(engine: engine, requested: requestedModel)

        await engine.reset()

        if stream {
            return .stream(
                LocalAPIServer.Response(status: 200, contentType: "text/event-stream"),
                lines: anthropicStream(
                    engine: engine, turns: turns, id: messageID, model: modelName, maxTokens: maxTokens))
        } else {
            return .response(await anthropicNonStreaming(
                engine: engine, turns: turns, id: messageID, model: modelName, maxTokens: maxTokens))
        }
    }

    private static func anthropicNonStreaming(
        engine: any LLMEngine, turns: [ChatTurn], id: String, model: String, maxTokens: Int?
    ) async -> LocalAPIServer.Response {
        var collected = ""
        do {
            let stream = engine.stream(adding: turns, maxTokens: maxTokens, temperature: nil)
            for try await chunk in stream {
                collected += chunk
            }
        } catch {
            return .json(anthropicError("Generation failed: \(error.localizedDescription)", type: "api_error"), status: 500)
        }
        let stats = await engine.stats
        return .json(LFJSONValue.object([
            "id": .string(id),
            "type": .string("message"),
            "role": .string("assistant"),
            "content": .array([
                .object(["type": .string("text"), "text": .string(collected)]),
            ]),
            "model": .string(model),
            "stop_reason": .string("end_turn"),
            "stop_sequence": .null,
            "usage": .object([
                "input_tokens": .number(0),
                "output_tokens": .number(Double(stats.generatedTokens)),
            ]),
        ]))
    }

    /// Anthropic's SSE protocol uses named events (`event: message_start`,
    /// …), unlike OpenAI's bare `data:` frames.
    private static func anthropicStream(
        engine: any LLMEngine, turns: [ChatTurn], id: String, model: String, maxTokens: Int?
    ) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                func frame(_ event: String, _ data: LFJSONValue) -> Data {
                    Data("event: \(event)\ndata: \(data.encoded())\n\n".utf8)
                }
                let messageObject = LFJSONValue.object([
                    "id": .string(id),
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array([]),
                    "model": .string(model),
                    "stop_reason": .null,
                    "stop_sequence": .null,
                    "usage": .object(["input_tokens": .number(0), "output_tokens": .number(1)]),
                ])
                continuation.yield(frame("message_start", .object([
                    "type": .string("message_start"),
                    "message": messageObject,
                ])))
                continuation.yield(frame("content_block_start", .object([
                    "type": .string("content_block_start"),
                    "index": .number(0),
                    "content_block": .object(["type": .string("text"), "text": .string("")]),
                ])))

                var caughtError: String?
                do {
                    let stream = engine.stream(adding: turns, maxTokens: maxTokens, temperature: nil)
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        if chunk.isEmpty { continue }
                        continuation.yield(frame("content_block_delta", .object([
                            "type": .string("content_block_delta"),
                            "index": .number(0),
                            "delta": .object(["type": .string("text_delta"), "text": .string(chunk)]),
                        ])))
                    }
                } catch {
                    caughtError = error.localizedDescription
                }

                continuation.yield(frame("content_block_stop", .object([
                    "type": .string("content_block_stop"),
                    "index": .number(0),
                ])))
                continuation.yield(frame("message_delta", .object([
                    "type": .string("message_delta"),
                    "delta": .object([
                        "stop_reason": .string(caughtError == nil ? "end_turn" : "error"),
                        "stop_sequence": .null,
                    ]),
                    "usage": .object(["output_tokens": .number(0)]),
                ])))
                continuation.yield(frame("message_stop", .object(["type": .string("message_stop")])))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func anthropicError(_ message: String, type: String) -> LFJSONValue {
        LFJSONValue.object([
            "type": .string("error"),
            "error": .object([
                "type": .string(type),
                "message": .string(message),
            ]),
        ])
    }

    // MARK: Errors

    static func errorJSON(message: String, type: String, code: String? = nil) -> LFJSONValue {
        var error: [String: LFJSONValue] = [
            "message": .string(message),
            "type": .string(type),
        ]
        if let code { error["code"] = .string(code) }
        return LFJSONValue.object(["error": .object(error)])
    }
}
