import Foundation
import XCTest
@testable import BeetCode

/// End-to-end tests for the local OpenAI-compatible API server: a real
/// `LocalAPIServer` bound to an ephemeral loopback port, driven by real HTTP
/// requests over URLSession. Covers routing, the stateless replay contract,
/// streaming (SSE), and error handling.
final class LocalAPIServerTests: XCTestCase {

    private var server: LocalAPIServer!
    private var engine: FakeLLMEngine!
    private var baseURL = ""

    override func setUp() async throws {
        engine = FakeLLMEngine()
        server = LocalAPIServer(engine: engine)
        // Port 0 → OS assigns a free port; no conflicts with other tests.
        try await server.start(.init(port: 0, bindIPv6: false, modelIDOverride: nil))
        let port = await server.actualPort
        baseURL = "http://127.0.0.1:\(port)"
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
        engine = nil
    }

    // MARK: Helpers

    private func get(_ path: String) async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: baseURL + path)!)
        let status = (response as! HTTPURLResponse).statusCode
        return (status, data)
    }

    private func post(_ path: String, json: String) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        return (status, data)
    }

    private static func postRequest(baseURL: String, json: String) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: baseURL + "/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    // MARK: Models & health

    func testModelsEndpointListsOverrideModel() async throws {
        let (status, data) = try await get("/v1/models")
        XCTAssertEqual(status, 200)
        let json = try LFJSONValue.decode(data)
        XCTAssertEqual(json.objectValue?["object"]?.stringValue, "list")
        let models = json.objectValue?["data"]?.arrayValue ?? []
        XCTAssertEqual(models.count, 1)
        // No model loaded → override/fallback id, loaded=false.
        XCTAssertEqual(models.first?.objectValue?["loaded"]?.boolValue, false)
    }

    func testHealthEndpoint() async throws {
        let (status, data) = try await get("/health")
        XCTAssertEqual(status, 200)
        let json = try LFJSONValue.decode(data)
        XCTAssertEqual(json.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(json.objectValue?["model_loaded"]?.boolValue, false)
    }

    func testUnknownEndpointIs404() async throws {
        let (status, _) = try await get("/v1/nope")
        XCTAssertEqual(status, 404)
    }

    // MARK: Non-streaming completions

    func testChatCompletionReturnsFullMessage() async throws {
        engine.enqueue(texts: ["Hello from BeetCode."])
        let body = #"{"model":"beetcode","messages":[{"role":"user","content":"Hi"}]}"#
        let (status, data) = try await post("/v1/chat/completions", json: body)
        XCTAssertEqual(status, 200)
        let json = try LFJSONValue.decode(data)
        XCTAssertEqual(json.objectValue?["object"]?.stringValue, "chat.completion")
        let choice = json.objectValue?["choices"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(choice?["message"]?.objectValue?["content"]?.stringValue, "Hello from BeetCode.")
        XCTAssertEqual(choice?["finish_reason"]?.stringValue, "stop")
    }

    /// The endpoint must be STATELESS: reset before streaming, and replay the
    /// entire conversation on every call (OpenAI chat semantics, not the
    /// engine's append-only KV-cache semantics).
    func testChatCompletionIsStateless() async throws {
        engine.enqueue(texts: ["first"])
        engine.enqueue(texts: ["second"])

        let body = #"""
        {"messages":[
          {"role":"system","content":"be brief"},
          {"role":"user","content":"one"},
          {"role":"assistant","content":"two"},
          {"role":"user","content":"three"}
        ]}
        """#
        _ = try await post("/v1/chat/completions", json: body)
        _ = try await post("/v1/chat/completions", json: body)

        XCTAssertEqual(engine.resetCallCount, 2, "every request resets the engine session")
        XCTAssertEqual(engine.turnHistory.count, 2)
        // Each call must have received ALL four turns, in order.
        for turns in engine.turnHistory {
            XCTAssertEqual(turns.map(\.content), ["be brief", "one", "two", "three"])
            XCTAssertEqual(turns.map(\.role), [.system, .user, .assistant, .user])
        }
    }

    func testChatCompletionValidationErrors() async throws {
        let (badStatus, badData) = try await post("/v1/chat/completions", json: #"{"messages":[]}"#)
        XCTAssertEqual(badStatus, 400)
        let badJSON = try LFJSONValue.decode(badData)
        XCTAssertNotNil(badJSON.objectValue?["error"]?.objectValue?["message"]?.stringValue)

        let (notJSONStatus, _) = try await post("/v1/chat/completions", json: "this is not json")
        XCTAssertEqual(notJSONStatus, 400)
    }

    /// Requested model names pass through — clients like Codex send their own
    /// model string and expect it echoed.
    func testRequestedModelNameIsEchoed() async throws {
        engine.enqueue(texts: ["ok"])
        let body = #"{"model":"gpt-oss-120b","messages":[{"role":"user","content":"Hi"}]}"#
        let (_, data) = try await post("/v1/chat/completions", json: body)
        let json = try LFJSONValue.decode(data)
        XCTAssertEqual(json.objectValue?["model"]?.stringValue, "gpt-oss-120b")
    }

    // MARK: Streaming (SSE)

    func testStreamingSSEDeliversChunksAndDone() async throws {
        engine.enqueue(texts: ["abc"])
        let body = #"{"messages":[{"role":"user","content":"Hi"}],"stream":true}"#
        var request = URLRequest(url: URL(string: baseURL + "/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertTrue(httpResponse.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") ?? false)

        var contentChunks: [String] = []
        var sawRoleDelta = false
        var sawFinishReason = false
        var sawDone = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" {
                sawDone = true
                continue
            }
            let json = try LFJSONValue.decode(payload)
            XCTAssertEqual(json.objectValue?["object"]?.stringValue, "chat.completion.chunk")
            let delta = json.objectValue?["choices"]?.arrayValue?.first?.objectValue?["delta"]?.objectValue ?? [:]
            if delta["role"]?.stringValue == "assistant" { sawRoleDelta = true }
            if let chunk = delta["content"]?.stringValue { contentChunks.append(chunk) }
            let finish = json.objectValue?["choices"]?.arrayValue?.first?.objectValue?["finish_reason"]
            if finish?.stringValue == "stop" { sawFinishReason = true }
        }
        XCTAssertEqual(contentChunks.joined(), "abc", "FakeLLMEngine streams one char at a time")
        XCTAssertTrue(sawRoleDelta)
        XCTAssertTrue(sawFinishReason)
        XCTAssertTrue(sawDone)
    }

    // MARK: CORS

    func testOptionsPreflight() async throws {
        var request = URLRequest(url: URL(string: baseURL + "/v1/chat/completions")!)
        request.httpMethod = "OPTIONS"
        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 204)
        XCTAssertNil(httpResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"),
                     "CORS must be opt-in")
    }

    func testConcurrentCompletionsAreSerialized() async throws {
        engine.enqueue(texts: ["first", "second"])
        engine.holdNextStream()
        let body = #"{"messages":[{"role":"user","content":"hello"}]}"#

        let requestBaseURL = baseURL
        async let firstResponse = Self.postRequest(baseURL: requestBaseURL, json: body)
        for _ in 0..<50 where engine.streamCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.streamCallCount, 1)

        async let secondResponse = Self.postRequest(baseURL: requestBaseURL, json: body)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.resetCallCount, 1,
                       "the second request must wait for the first generation")

        engine.release()
        let firstResult = try await firstResponse
        let secondResult = try await secondResponse
        XCTAssertEqual(firstResult.0, 200)
        XCTAssertEqual(secondResult.0, 200)
        XCTAssertEqual(engine.resetCallCount, 2)
        XCTAssertEqual(engine.turnHistory.count, 2)
    }

    // MARK: Anthropic-format /v1/messages

    func testAnthropicMessagesNonStreaming() async throws {
        engine.enqueue(texts: ["Hi from the messages route."])
        let body = #"""
        {"model":"claude-3-5-sonnet","system":"be brief",
         "messages":[{"role":"user","content":"hello"}],"max_tokens":64}
        """#
        let (status, data) = try await post("/v1/messages", json: body)
        XCTAssertEqual(status, 200)
        let json = try LFJSONValue.decode(data)
        XCTAssertEqual(json.objectValue?["type"]?.stringValue, "message")
        XCTAssertEqual(json.objectValue?["role"]?.stringValue, "assistant")
        XCTAssertEqual(json.objectValue?["stop_reason"]?.stringValue, "end_turn")
        let block = json.objectValue?["content"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(block?["type"]?.stringValue, "text")
        XCTAssertEqual(block?["text"]?.stringValue, "Hi from the messages route.")
        // The requested model string is echoed, like the OpenAI route.
        XCTAssertEqual(json.objectValue?["model"]?.stringValue, "claude-3-5-sonnet")
    }

    /// The top-level `system` field must become a system turn, and the full
    /// conversation must be replayed (stateless contract).
    func testAnthropicMessagesIsStateless() async throws {
        engine.enqueue(texts: ["one"])
        engine.enqueue(texts: ["two"])
        let body = #"""
        {"system":"sys","messages":[
          {"role":"user","content":"u1"},
          {"role":"assistant","content":"a1"},
          {"role":"user","content":"u2"}
        ]}
        """#
        _ = try await post("/v1/messages", json: body)
        _ = try await post("/v1/messages", json: body)

        XCTAssertEqual(engine.resetCallCount, 2)
        XCTAssertEqual(engine.turnHistory.count, 2)
        for turns in engine.turnHistory {
            XCTAssertEqual(turns.map(\.content), ["sys", "u1", "a1", "u2"])
            XCTAssertEqual(turns.map(\.role), [.system, .user, .assistant, .user])
        }
    }

    func testAnthropicMessagesValidation() async throws {
        let (status, data) = try await post("/v1/messages", json: #"{"messages":[]}"#)
        XCTAssertEqual(status, 400)
        let json = try LFJSONValue.decode(data)
        XCTAssertEqual(json.objectValue?["type"]?.stringValue, "error")
        XCTAssertNotNil(json.objectValue?["error"]?.objectValue?["message"]?.stringValue)
    }

    func testAnthropicMessagesStreaming() async throws {
        engine.enqueue(texts: ["xy"])
        var request = URLRequest(url: URL(string: baseURL + "/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)

        // Anthropic SSE: `event:` lines carry the named event type.
        var events: [String] = []
        var deltas: [String] = []
        var currentEvent = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst(7))
                events.append(currentEvent)
            } else if line.hasPrefix("data: ") {
                if currentEvent == "content_block_delta" {
                    let json = try LFJSONValue.decode(String(line.dropFirst(6)))
                    if let text = json.objectValue?["delta"]?.objectValue?["text"]?.stringValue {
                        deltas.append(text)
                    }
                }
            }
        }
        XCTAssertEqual(deltas.joined(), "xy")
        XCTAssertEqual(events.first, "message_start")
        XCTAssertTrue(events.contains("content_block_start"))
        XCTAssertTrue(events.contains("content_block_delta"))
        XCTAssertTrue(events.contains("content_block_stop"))
        XCTAssertTrue(events.contains("message_delta"))
        XCTAssertEqual(events.last, "message_stop")
    }
}

/// Bearer-token auth: a second server instance with auth configured. Kept in
/// its own class so the main suite's unauthenticated fixtures stay simple.
final class LocalAPIServerAuthTests: XCTestCase {

    private var server: LocalAPIServer!
    private var engine: FakeLLMEngine!
    private var baseURL = ""

    override func setUp() async throws {
        engine = FakeLLMEngine()
        server = LocalAPIServer(engine: engine)
        try await server.start(.init(port: 0, bindIPv6: false, modelIDOverride: nil, bearerToken: "secret-token"))
        baseURL = "http://127.0.0.1:\(await server.actualPort)"
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
        engine = nil
    }

    private func post(_ path: String, json: String, token: String?) async throws -> Int {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(json.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    func testMissingTokenIs401() async throws {
        let status = try await post("/v1/chat/completions", json: #"{"messages":[{"role":"user","content":"hi"}]}"#, token: nil)
        XCTAssertEqual(status, 401)
    }

    func testWrongTokenIs403() async throws {
        let status = try await post("/v1/chat/completions", json: #"{"messages":[{"role":"user","content":"hi"}]}"#, token: "wrong")
        XCTAssertEqual(status, 403)
    }

    func testCorrectTokenSucceeds() async throws {
        engine.enqueue(texts: ["authorized"])
        let status = try await post("/v1/chat/completions", json: #"{"messages":[{"role":"user","content":"hi"}]}"#, token: "secret-token")
        XCTAssertEqual(status, 200)
    }

    /// Health stays open so monitoring never needs credentials.
    func testHealthIsExempt() async throws {
        let (data, response) = try await URLSession.shared.data(from: URL(string: baseURL + "/health")!)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        let json = try LFJSONValue.decode(data)
        XCTAssertEqual(json.objectValue?["status"]?.stringValue, "ok")
    }
}
