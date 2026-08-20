import XCTest
@testable import BeetCode

private final class ProviderFixtureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var responder: @Sendable (URLRequest) -> (status: Int, data: Data) = { _ in
        (200, Data())
    }
    private(set) var requests: [URLRequest] = []

    func setResponder(_ responder: @escaping @Sendable (URLRequest) -> (status: Int, data: Data)) {
        lock.lock()
        self.responder = responder
        requests.removeAll()
        lock.unlock()
    }

    func response(for request: URLRequest) -> (status: Int, data: Data) {
        lock.lock()
        requests.append(request)
        let result = responder(request)
        lock.unlock()
        return result
    }

    func snapshotRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private let providerFixtureStore = ProviderFixtureStore()

private final class ProviderFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = providerFixtureStore.response(for: request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: fixture.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Regression tests for the provider audit fixes (P1–P13). All offline —
/// they exercise the pure preparation/parsing layers, never the network.
final class ProviderAuditTests: XCTestCase {

    // MARK: P1 — UTF-8-safe SSE parsing

    func testSSEMultibyteCharacterSplitAcrossChunks() async throws {
        // "data: {"choices":[{"delta":{"content":"中文"}}]}" — the UTF-8
        // bytes of 中文 are split across two simulated network chunks, which
        // the old per-byte String decoding corrupted to U+FFFD.
        let payload = #"data: {"choices":[{"delta":{"content":"中文"}}]}"#
        let full = Array(Data(payload.utf8)) + [0x0A]  // + newline
        // Split inside the multi-byte character.
        let split = Data(payload.utf8).firstIndex(of: 0x88) ?? 10  // 中 is E4 B8 AD
        _ = split
        let chunkA = Array(full[0..<20])
        let chunkB = Array(full[20...])

        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in chunkA { continuation.yield(byte) }
            for byte in chunkB { continuation.yield(byte) }
            continuation.finish()
        }

        var collected = ""
        final class Box: @unchecked Sendable { var text = "" }
        let box = Box()
        try await RemoteLLMClient.consumeSSE(bytes: stream) { text in
            box.text += text
        } onUsage: { _ in }
        collected = box.text
        XCTAssertEqual(collected, "中文", "multi-byte chars must survive chunk splits")
    }

    func testSSEDoneAndKeepaliveIgnored() async throws {
        let raw = ": keep-alive\n"
            + #"data: {"choices":[{"delta":{"content":"ok"}}]}"# + "\n"
            + "data: [DONE]\n"
            // Anything after [DONE] must never be delivered.
            + #"data: {"choices":[{"delta":{"content":"never"}}]}"# + "\n"
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in Array(Data(raw.utf8)) { continuation.yield(byte) }
            continuation.finish()
        }
        var collected: [String] = []
        final class Box: @unchecked Sendable { var texts: [String] = [] }
        let box = Box()
        try await RemoteLLMClient.consumeSSE(bytes: stream) { text in
            box.texts.append(text)
        } onUsage: { _ in }
        collected = box.texts
        XCTAssertEqual(collected, ["ok"])
    }

    func testSSEUsageChunkExtracted() async throws {
        let raw = #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"# + "\n"
            + "data: [DONE]\n"
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in Array(Data(raw.utf8)) { continuation.yield(byte) }
            continuation.finish()
        }
        final class UBox: @unchecked Sendable { var usage: RemoteLLMClient.UsageInfo? }
        let ubox = UBox()
        try await RemoteLLMClient.consumeSSE(bytes: stream, onText: { _ in }, onUsage: { ubox.usage = $0 })
        XCTAssertEqual(ubox.usage, .init(promptTokens: 10, completionTokens: 5))
    }

    // MARK: P2 — tool-role translation

    func testOpenAIToolRoleBecomesMarkedUserMessage() {
        let turns = [
            ChatTurn(role: .system, content: "sys"),
            ChatTurn(role: .user, content: "hi"),
            ChatTurn(role: .assistant, content: "ok"),
            ChatTurn(role: .tool, content: "file contents"),
        ]
        let messages = RemoteLLMClient.prepareOpenAIMessages(turns)
        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertTrue(messages[3].content.hasPrefix("[tool result] "))
        XCTAssertFalse(messages.contains { $0.role == "tool" },
                       "raw tool role 400s on OpenAI without tool_call pairing")
    }

    // MARK: P7 — Gemini systemInstruction + alternation

    func testGeminiSystemGoesToInstructionAndRolesAlternate() {
        let turns = [
            ChatTurn(role: .system, content: "be terse"),
            ChatTurn(role: .user, content: "a"),
            ChatTurn(role: .user, content: "b"),       // adjacent same-role
            ChatTurn(role: .assistant, content: "c"),
            ChatTurn(role: .tool, content: "d"),        // tool -> user
        ]
        let (system, contents) = RemoteLLMClient.prepareGeminiPayload(turns)
        XCTAssertEqual(system, "be terse")
        XCTAssertEqual(contents.count, 3, "adjacent same-role turns must merge")
        XCTAssertEqual(contents.map(\.role), ["user", "model", "user"])
        XCTAssertTrue(contents[2].parts.contains { ($0.text ?? "").contains("[tool result] d") })
        // No system text may leak into user content.
        XCTAssertFalse(contents[0].parts.contains { ($0.text ?? "").contains("be terse") })
    }

    // MARK: P5 — Anthropic payload shape

    func testAnthropicAlternationAndLeadingUser() {
        let turns = [
            ChatTurn(role: .system, content: "sys"),
            ChatTurn(role: .assistant, content: "first"),
            ChatTurn(role: .user, content: "u"),
        ]
        let (system, messages) = RemoteLLMClient.prepareAnthropicPayload(turns)
        XCTAssertEqual(system, "sys")
        XCTAssertEqual(messages.first?.role, "user", "Anthropic requires a leading user message")
        XCTAssertEqual(messages.map(\.role).filter { $0 == "assistant" }.count, 1)
    }

    // MARK: P3/P8 — model-family heuristics

    func testReasoningModelHeuristics() {
        XCTAssertTrue(RemoteLLMClient.usesMaxCompletionTokens("o3-mini"))
        XCTAssertTrue(RemoteLLMClient.usesMaxCompletionTokens("gpt-5-chat"))
        XCTAssertFalse(RemoteLLMClient.usesMaxCompletionTokens("gpt-4o"))
        XCTAssertTrue(RemoteLLMClient.omitsTemperature("deepseek-reasoner"))
        XCTAssertTrue(RemoteLLMClient.omitsTemperature("o4-mini"))
        XCTAssertFalse(RemoteLLMClient.omitsTemperature("deepseek-chat"))
    }

    // MARK: P4/P5 — provider registry additions

    func testProviderRegistryExtensions() {
        XCTAssertEqual(LLMProvider.allCases.count, 11)
        XCTAssertNotNil(LLMProvider.anthropic.anthropicBaseURL)
        XCTAssertEqual(LLMProvider.anthropic.anthropicBaseURL?.host, "api.anthropic.com")
        XCTAssertNil(LLMProvider.anthropic.openAICompatibleBaseURL)
        XCTAssertTrue(LLMProvider.custom.keyOptional)
        XCTAssertFalse(LLMProvider.openAI.keyOptional)
        // Custom has no URL until configured (prefs untouched by tests —
        // customBaseURL defaults to nil in a fresh prefs store).
        XCTAssertEqual(LLMProvider.custom.defaultModel, "")
    }

    func testCurrentProviderDefaultsAndRoutes() {
        XCTAssertEqual(LLMProvider.longCat.defaultModel, "LongCat-2.0")
        XCTAssertEqual(LLMProvider.longCat.suggestedModels, ["LongCat-2.0"])
        XCTAssertEqual(LLMProvider.longCat.openAICompatibleBaseURL?.absoluteString,
                       "https://api.longcat.chat/openai/v1")
        XCTAssertEqual(LLMProvider.longCat.modelsURL?.absoluteString,
                       "https://api.longcat.chat/openai/v1/models")
        XCTAssertEqual(LLMProvider.gemini.defaultModel, "gemini-3.7-flash")
        XCTAssertEqual(LLMProvider.openCode.openAICompatibleBaseURL?.absoluteString,
                       "https://opencode.ai/zen/v1")
        XCTAssertEqual(LLMProvider.openCode.modelsURL?.absoluteString,
                       "https://opencode.ai/zen/v1/models")
    }

    func testCompatibleModelCatalogAcceptsCommonGatewayEnvelopes() throws {
        let bodies = [
            #"[{"id":"array-model"}]"#,
            #"{"models":[{"model":"models-key"}]}"#,
            #"{"results":[{"name":"result-model","display_name":"Result"}]}"#
        ]
        let names = try bodies.flatMap {
            try RemoteLLMClient.compatibleModelProfiles(
                from: Data($0.utf8), provider: .openCode).map(\.model)
        }
        XCTAssertEqual(names, ["array-model", "models-key", "result-model"])
    }

    // MARK: Deterministic provider contract fixtures

    func testLongCatModelListFixtureUsesOpenAIContract() async throws {
        providerFixtureStore.setResponder { _ in
            let body = #"{"data":[{"id":"LongCat-2.0","name":"LongCat 2"},{"id":"LongCat-2.0-thinking"}]}"#
            return (200, Data(body.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let profiles = try await RemoteLLMClient.fetchModelProfiles(
            provider: .longCat, apiKey: "fixture-key", session: session)

        XCTAssertEqual(profiles.map(\.model), ["LongCat-2.0", "LongCat-2.0-thinking"])
        let request = try XCTUnwrap(providerFixtureStore.snapshotRequests().first)
        XCTAssertEqual(request.url?.path, "/openai/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
    }

    func testGeminiModelListFixturePaginatesAndKeepsCapabilities() async throws {
        providerFixtureStore.setResponder { request in
            let isSecondPage = request.url?.query?.contains("pageToken=next") == true
            if isSecondPage {
                let body = #"{"models":[{"name":"models/future-coder","inputTokenLimit":32768,"outputTokenLimit":4096,"supportedGenerationMethods":["generateContent"]}]}"#
                return (200, Data(body.utf8))
            }
            let body = #"{"models":[{"name":"models/not-an-embedder","displayName":"Coder","inputTokenLimit":16384,"outputTokenLimit":2048,"supportedGenerationMethods":["generateContent"],"supportsVision":true},{"name":"models/embed","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"next"}"#
            return (200, Data(body.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let profiles = try await RemoteLLMClient.fetchModelProfiles(
            provider: .gemini, apiKey: "gemini-fixture", session: session)

        XCTAssertEqual(profiles.map(\.model), ["future-coder", "not-an-embedder"])
        let coder = try XCTUnwrap(profiles.first { $0.model == "not-an-embedder" })
        XCTAssertEqual(coder.contextWindow, 16_384)
        XCTAssertEqual(coder.maxOutputTokens, 2_048)
        XCTAssertEqual(coder.supportsTools, true)
        XCTAssertEqual(coder.supportsVision, true)
        XCTAssertEqual(providerFixtureStore.snapshotRequests().count, 2)
    }

    func testProviderErrorFixturePreservesHTTPStatusAndMessage() async throws {
        providerFixtureStore.setResponder { _ in
            let body = #"{"error":{"message":"invalid api key"}}"#
            return (401, Data(body.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)

        do {
            _ = try await RemoteLLMClient.fetchModels(
                provider: .longCat, apiKey: "bad", session: session)
            XCTFail("fixture should return a provider error")
        } catch let error as RemoteLLMError {
            guard case .badStatus(let code, let detail) = error else {
                return XCTFail("unexpected remote error: \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertTrue(detail.contains("invalid api key"))
        }
    }

    func testStreamingFixturesCoverOpenAIGeminiAndAnthropicShapes() {
        let openAI = RemoteLLMClient.processSSELine(
            Array(Data(#"data: {"choices":[{"delta":{"content":"hello"}}]}"#.utf8)))
        XCTAssertEqual(openAI, .text("hello"))

        let gemini = RemoteLLMClient.processSSELine(
            Array(Data(#"data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"read_file","args":{"path":"README.md"}}}]}}]}"#.utf8)))
        guard case .toolFragment(let index, let name, let arguments) = gemini else {
            return XCTFail("Gemini function calls must remain a tool fragment")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(name, "read_file")
        XCTAssertTrue(arguments?.contains("README.md") == true)

        let anthropic = RemoteLLMClient.processSSELine(
            Array(Data(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"README.md\"}"}}"#.utf8)))
        guard case .toolFragment(let anthropicIndex, _, let partial) = anthropic else {
            return XCTFail("Anthropic input_json_delta must remain a tool fragment")
        }
        XCTAssertEqual(anthropicIndex, 0)
        XCTAssertTrue(partial?.contains("README.md") == true)
    }

    func testGeminiModelFilteringUsesGenerationCapability() {
        let valid = RemoteLLMClient.GeminiModelEntry(
            name: "models/gemini-3.7-flash",
            supportedGenerationMethods: ["countTokens", "generateContent"])
        let validAlias = RemoteLLMClient.GeminiModelEntry(
            name: "models/future-coding-alias",
            supportedGenerationMethods: ["generateContent"])
        let embedding = RemoteLLMClient.GeminiModelEntry(
            name: "models/text-embedding-005",
            supportedGenerationMethods: ["embedContent"])

        XCTAssertEqual(RemoteLLMClient.geminiModelID(from: valid), "gemini-3.7-flash")
        XCTAssertEqual(RemoteLLMClient.geminiModelID(from: validAlias), "future-coding-alias")
        XCTAssertNil(RemoteLLMClient.geminiModelID(from: embedding))
    }

    func testGeminiModelIDsAcceptShortAndQualifiedForms() {
        XCTAssertEqual(RemoteLLMClient.normalizedGeminiModelID("gemini-3.7-flash"), "gemini-3.7-flash")
        XCTAssertEqual(RemoteLLMClient.normalizedGeminiModelID("models/gemini-3.7-flash"), "gemini-3.7-flash")
    }

    // MARK: P9 — usage wire types

    func testOpenAIUsageChunkDecodes() {
        let json = #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":40}}"#
        let decoded = try? JSONDecoder().decode(RemoteLLMClient.OpenAIChunk.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?.usage?.completion_tokens, 40)
    }

    func testGeminiUsageMetadataDecodes() {
        let json = #"{"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":7}}"#
        let decoded = try? JSONDecoder().decode(RemoteLLMClient.GeminiChunk.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?.usageMetadata?.candidatesTokenCount, 7)
    }

    func testAnthropicDeltaDecodes() {
        let json = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}"#
        XCTAssertEqual(RemoteLLMClient.extractText(from: Data(json.utf8)), "hi")
        let thinking = #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        XCTAssertEqual(RemoteLLMClient.extractText(from: Data(thinking.utf8)), "<think>hmm</think>")
    }

    func testGeminiThoughtPartStaysOnReasoningChannel() {
        let json = #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"inspect the project"},{"text":"The answer"}]}}]}"#
        XCTAssertEqual(
            RemoteLLMClient.extractText(from: Data(json.utf8)),
            "<think>inspect the project</think>The answer")
    }

    func testOpenAIReasoningAndAnswerInOneDeltaAreBothPreserved() {
        let json = #"{"choices":[{"delta":{"reasoning_content":"inspect the project","content":"The answer"}}]}"#
        XCTAssertEqual(
            RemoteLLMClient.extractText(from: Data(json.utf8)),
            "<think>inspect the project</think>The answer")
    }

    func testOpenAIReasoningIsPreservedAlongsideToolDelta() {
        let json = #"{"choices":[{"delta":{"reasoning_content":"inspect the project","tool_calls":[{"index":0,"function":{"name":"read_file"}}]}}]}"#
        let extracted = RemoteLLMClient.extract(from: Data(json.utf8))

        XCTAssertEqual(extracted?.text, "<think>inspect the project</think>")
        XCTAssertEqual(extracted?.tool?.index, 0)
        XCTAssertEqual(extracted?.tool?.name, "read_file")
    }

    func testSSELinePreservesTextAlongsideToolDelta() {
        let json = #"data: {"choices":[{"delta":{"reasoning_content":"inspect","tool_calls":[{"index":0,"function":{"name":"read_file"}}]}}]}"#
        guard case .textAndToolFragment(
            text: let text,
            index: let index,
            name: let name,
            arguments: let arguments) = RemoteLLMClient.processSSELine(Array(json.utf8))
        else {
            return XCTFail("reasoning and tool data must share one SSE action")
        }

        XCTAssertEqual(text, "<think>inspect</think>")
        XCTAssertEqual(index, 0)
        XCTAssertEqual(name, "read_file")
        XCTAssertNil(arguments)
    }

    func testSSELinePreservesTextAndUsageTogether() {
        let json = #"data: {"choices":[{"delta":{"content":"done"}}],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#
        guard case .textAndUsage(let text, let usage) = RemoteLLMClient.processSSELine(Array(json.utf8)) else {
            return XCTFail("a final chunk must not drop either text or usage")
        }
        XCTAssertEqual(text, "done")
        XCTAssertEqual(usage.promptTokens, 12)
        XCTAssertEqual(usage.completionTokens, 3)
    }

    // MARK: Browser — JS literal escaping (the only arg→JS boundary)

    func testJSLiteralEscapesInjectionAttempts() {
        let evil = #""); document.location='x';(""#
        let literal = BrowserController.jsLiteral(evil)
        XCTAssertTrue(literal.hasPrefix("\"") && literal.hasSuffix("\""))
        // The inner payload must contain no RAW quote — only escaped \".
        let inner = String(literal.dropFirst().dropLast())
        var rawQuoteCount = 0
        var i = inner.startIndex
        while i < inner.endIndex {
            if inner[i] == "\\" { i = inner.index(i, offsetBy: 2, limitedBy: inner.endIndex) ?? inner.endIndex; continue }
            if inner[i] == "\"" { rawQuoteCount += 1 }
            i = inner.index(after: i)
        }
        XCTAssertEqual(rawQuoteCount, 0, "an escaped literal must contain no unescaped quotes")
        XCTAssertEqual(BrowserController.jsLiteral("line\nbreak"), "\"line\\nbreak\"")
        XCTAssertEqual(BrowserController.jsLiteral("sep\u{2028}line"), "\"sep\\u2028line\"")
    }

    // MARK: Browser URL confinement

    func testBrowserAllowsHTTPSAndBareHosts() throws {
        let url = try BrowserURLValidator.validatedURL("example.com", filePolicy: .refuse)
        XCTAssertEqual(url.absoluteString, "https://example.com")
        let https = try BrowserURLValidator.validatedURL("https://beetcode.app/docs", filePolicy: .refuse)
        XCTAssertEqual(https.host, "beetcode.app")
    }

    func testBrowserRejectsJavascriptAndDataSchemes() {
        XCTAssertThrowsError(try BrowserURLValidator.validatedURL("javascript:alert(1)", filePolicy: .allowAny))
        XCTAssertThrowsError(try BrowserURLValidator.validatedURL("data:text/html,hi", filePolicy: .allowAny))
    }

    func testBrowserFileURLConfinedToWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.html")
        try "<p>hi</p>".write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace(root: root)

        let allowed = try BrowserURLValidator.validatedURL(
            file.absoluteString, filePolicy: .confined(workspace))
        XCTAssertEqual(allowed.path, file.path)

        XCTAssertThrowsError(
            try BrowserURLValidator.validatedURL("file:///etc/passwd", filePolicy: .confined(workspace)))
        XCTAssertThrowsError(
            try BrowserURLValidator.validatedURL("file:///etc/passwd", filePolicy: .refuse))
    }

    func testWebFetchRejectsNonHTTPSchemes() {
        XCTAssertThrowsError(try WebFetchPolicy.validatedURL("file:///etc/passwd"))
        XCTAssertThrowsError(try WebFetchPolicy.validatedURL("javascript:alert(1)"))
        XCTAssertThrowsError(try WebFetchPolicy.validatedURL("data:text/html,hi"))
    }

    func testWebFetchAllowsHTTPSAndBareHosts() throws {
        XCTAssertEqual(try WebFetchPolicy.validatedURL("example.com").absoluteString, "https://example.com")
        XCTAssertEqual(try WebFetchPolicy.validatedURL("https://beetcode.app/docs").host, "beetcode.app")
    }

    func testHTMLTextStripsTagsAndScripts() {
        let html = "<html><script>secret()</script><style>p{}</style><p>Hello &amp; world</p></html>"
        let text = HTMLText.extract(html, limit: 200)
        XCTAssertTrue(text.contains("Hello & world"), text)
        XCTAssertFalse(text.contains("secret"), text)
        XCTAssertFalse(text.contains("<p>"), text)
    }

    func testHTMLTextTruncates() {
        let text = HTMLText.extract(String(repeating: "a", count: 80), limit: 20)
        XCTAssertTrue(text.hasSuffix("…[truncated]"))
        XCTAssertTrue(text.hasPrefix("aaaaaaaaaaaaaaaaaaaa"))
    }

    func testSessionUsageAccumulatesAndEstimates() {
        var usage = SessionUsage()
        usage.add(prompt: 1000, completion: 400)
        usage.add(prompt: 500, completion: 100)
        XCTAssertEqual(usage.promptTokens, 1500)
        XCTAssertEqual(usage.completionTokens, 500)
        XCTAssertEqual(usage.totalTokens, 2000)
        XCTAssertEqual(usage.turns, 2)
        XCTAssertNotNil(usage.estimatedUSD(provider: .openAI))
        XCTAssertNil(usage.estimatedUSD(provider: .custom))
        XCTAssertTrue(usage.compactLabel(provider: .openAI).contains("tok"))
    }
}
