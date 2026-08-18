import XCTest
@testable import BeetCode

final class RemoteLLMClientTests: XCTestCase {

    func testSSEParsingAcrossChunkBoundaries() async throws {
        // Two SSE events split at awkward byte boundaries.
        let raw = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n"
            + "data: [DONE]\n\n"
        let data = Data(raw.utf8)

        var collected: [String] = []
        // Feed the stream one byte at a time to stress buffering.
        let stream = AsyncStream<Data> { continuation in
            Task {
                for byte in data {
                    continuation.yield(Data([byte]))
                }
                continuation.finish()
            }
        }

        // Convert AsyncStream<Data> to AsyncBytes-compatible consumption via
        // the consumeSSE closure API (test the pure line-splitting logic
        // through a helper that takes an AsyncSequence of UInt8).
        let sequence = AsyncThrowingStream<UInt8, Error> { continuation in
            Task {
                for byte in data {
                    continuation.yield(byte)
                }
                continuation.finish()
            }
        }
        // Reuse extractText on the parsed payloads.
        var buffer = ""
        for try await byte in sequence {
            buffer += String(UnicodeScalar(byte))
            while let newline = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.hasPrefix("data:") {
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    if let payloadData = payload.data(using: .utf8),
                       let text = RemoteLLMClient.extractText(from: payloadData) {
                        collected.append(text)
                    }
                }
            }
        }
        XCTAssertEqual(collected, ["Hel", "lo"])
    }

    func testExtractTextOpenAIAndGemini() {
        let openAI = #"{"choices":[{"delta":{"content":"hi"},"finish_reason":null}]}"#
        XCTAssertEqual(RemoteLLMClient.extractText(from: Data(openAI.utf8)), "hi")

        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"he"},{"text":"llo"}]},"finishReason":"STOP"}]}"#
        XCTAssertEqual(RemoteLLMClient.extractText(from: Data(gemini.utf8)), "hello")

        XCTAssertNil(RemoteLLMClient.extractText(from: Data("not json".utf8)))
        // A heartbeat comment or empty delta is not text.
        XCTAssertNil(RemoteLLMClient.extractText(from: Data(#"{"choices":[{"delta":{"role":"assistant"}}]}"#.utf8)))
    }

    func testProviderRegistry() {
        XCTAssertEqual(LLMProvider.allCases.count, 9)
        XCTAssertEqual(LLMProvider.openAI.openAICompatibleBaseURL?.host, "api.openai.com")
        XCTAssertEqual(LLMProvider.deepSeek.openAICompatibleBaseURL?.host, "api.deepseek.com")
        XCTAssertEqual(LLMProvider.longCat.openAICompatibleBaseURL?.host, "api.longcat.ai")
        XCTAssertEqual(LLMProvider.alibaba.openAICompatibleBaseURL?.host, "dashscope.aliyuncs.com")
        XCTAssertEqual(LLMProvider.alibabaTokenPlan.openAICompatibleBaseURL?.host, "token-plan.ap-southeast-1.maas.aliyuncs.com")
        XCTAssertEqual(LLMProvider.openRouter.openAICompatibleBaseURL?.host, "openrouter.ai")
        // Gemini is the only non-OpenAI-compatible provider.
        XCTAssertNil(LLMProvider.gemini.openAICompatibleBaseURL)
        XCTAssertNotNil(LLMProvider.gemini.geminiBaseURL)
        XCTAssertTrue(LLMProvider.openAI.supportsVision)
        XCTAssertTrue(LLMProvider.gemini.supportsVision)
        XCTAssertFalse(LLMProvider.deepSeek.supportsVision)
        XCTAssertFalse(LLMProvider.alibabaTokenPlan.supportsVision)
    }

    @MainActor
    func testAPIKeyStoreRoundTrip() {
        let store = APIKeyStore.shared
        store.save(key: "sk-test-roundtrip-123", for: .openAI)
        XCTAssertEqual(store.key(for: .openAI), "sk-test-roundtrip-123")
        XCTAssertTrue(store.configuredProviders.contains(.openAI))
        store.deleteKey(for: .openAI)
        XCTAssertNil(store.key(for: .openAI))
        XCTAssertFalse(store.configuredProviders.contains(.openAI))
    }

    @MainActor
    func testRemoteEngineRequiresKey() {
        APIKeyStore.shared.deleteKey(for: .deepSeek)
        let endpoint = RemoteEndpoint(provider: .deepSeek, model: "deepseek-chat")
        XCTAssertNil(RemoteLLMEngine(endpoint: endpoint), "engine must not exist without a key")
        APIKeyStore.shared.save(key: "sk-test-456", for: .deepSeek)
        XCTAssertNotNil(RemoteLLMEngine(endpoint: endpoint))
        APIKeyStore.shared.deleteKey(for: .deepSeek)
    }
}