import CryptoKit
import Foundation
import XCTest
@testable import BeetCode

// MARK: - Parallel chunk planning

final class ParallelChunkPlannerTests: XCTestCase {

    func testPlanSplitsExactMultiples() {
        let chunks = ParallelChunkDownloader.Logic.plan(totalBytes: 512, chunkSize: 128)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks.map(\.offset), [0, 128, 256, 384])
        XCTAssertEqual(chunks.map(\.length), [128, 128, 128, 128])
    }

    func testPlanLastChunkAbsorbsRemainder() {
        let chunks = ParallelChunkDownloader.Logic.plan(totalBytes: 300, chunkSize: 128)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[2].offset, 256)
        XCTAssertEqual(chunks[2].length, 44)
        // Chunks tile the file exactly — no gaps, no overlaps.
        var cursor: Int64 = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.offset, cursor)
            cursor += chunk.length
        }
        XCTAssertEqual(cursor, 300)
    }

    func testPlanSingleChunkForSmallFile() {
        let chunks = ParallelChunkDownloader.Logic.plan(totalBytes: 10, chunkSize: 128)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].offset, 0)
        XCTAssertEqual(chunks[0].length, 10)
    }

    func testPlanEmptyForInvalidInputs() {
        XCTAssertTrue(ParallelChunkDownloader.Logic.plan(totalBytes: 0, chunkSize: 128).isEmpty)
        XCTAssertTrue(ParallelChunkDownloader.Logic.plan(totalBytes: -5, chunkSize: 128).isEmpty)
        XCTAssertTrue(ParallelChunkDownloader.Logic.plan(totalBytes: 100, chunkSize: 0).isEmpty)
    }

    func testRangeHeaderValueIsInclusiveEnd() {
        let chunk = ParallelChunkDownloader.Chunk(index: 1, offset: 128, length: 128)
        XCTAssertEqual(chunk.rangeHeader, "bytes=128-255")
    }

    func testSidecarReuseRequiresSameEtagAndSize() {
        let sidecar = ParallelChunkDownloader.SidecarState(
            etag: "abc", totalBytes: 1000, completedChunks: [0])
        XCTAssertTrue(ParallelChunkDownloader.Logic.canReuseSidecar(
            sidecar, etag: "abc", totalBytes: 1000))
        XCTAssertFalse(ParallelChunkDownloader.Logic.canReuseSidecar(
            sidecar, etag: "changed", totalBytes: 1000))
        XCTAssertFalse(ParallelChunkDownloader.Logic.canReuseSidecar(
            sidecar, etag: "abc", totalBytes: 999))
        XCTAssertFalse(ParallelChunkDownloader.Logic.canReuseSidecar(
            nil, etag: "abc", totalBytes: 1000))
    }

    func testConcurrencyIsBounded() {
        XCTAssertEqual(
            ParallelChunkDownloader.Logic.concurrency(totalBytes: 1_000_000_000, chunkCount: 30), 4)
        XCTAssertEqual(
            ParallelChunkDownloader.Logic.concurrency(totalBytes: 1_000_000_000, chunkCount: 2), 2)
        XCTAssertEqual(
            ParallelChunkDownloader.Logic.concurrency(totalBytes: 0, chunkCount: 5), 1)
    }

    func testParallelizationThreshold() {
        XCTAssertFalse(ParallelChunkDownloader.Logic.shouldParallelize(totalBytes: 1_000))
        XCTAssertFalse(ParallelChunkDownloader.Logic.shouldParallelize(totalBytes: 256 * 1024 * 1024 - 1))
        XCTAssertTrue(ParallelChunkDownloader.Logic.shouldParallelize(totalBytes: 256 * 1024 * 1024))
        XCTAssertTrue(ParallelChunkDownloader.Logic.shouldParallelize(totalBytes: 17_000_000_000))
    }
}

// MARK: - Engine pool residency

final class EnginePoolTests: XCTestCase {

    private func makeResident(_ id: String, used: Date, bytes: Int64 = 1_000) -> EnginePool.Resident {
        EnginePool.Resident(modelID: id, directory: URL(fileURLWithPath: "/tmp/\(id)"), diskBytes: bytes, lastUsed: used)
    }

    func testEvictionCandidatesExcludeActiveAndSortLRU() {
        let t0 = Date()
        let residents = [
            makeResident("old", used: t0.addingTimeInterval(-300)),
            makeResident("active", used: t0.addingTimeInterval(-10)),
            makeResident("mid", used: t0.addingTimeInterval(-100)),
        ]
        let candidates = EnginePool.Planner.evictionCandidates(
            residents: residents, activeModelID: "active")
        XCTAssertEqual(candidates.map(\.modelID), ["old", "mid"],
                       "LRU order, active model never a candidate")
    }

    func testEvictionCandidatesEmptyWhenOnlyActive() {
        let candidates = EnginePool.Planner.evictionCandidates(
            residents: [makeResident("only", used: Date())], activeModelID: "only")
        XCTAssertTrue(candidates.isEmpty)
    }

    func testUnderCap() {
        XCTAssertTrue(EnginePool.Planner.underCap(residentCount: 0, maxResident: 4))
        XCTAssertTrue(EnginePool.Planner.underCap(residentCount: 3, maxResident: 4))
        XCTAssertFalse(EnginePool.Planner.underCap(residentCount: 4, maxResident: 4))
    }

    func testActivateLoadsAndSwitchesWarm() async throws {
        let pool = EnginePool(maxResident: 3)
        await pool.setAdmitLoad { _ in }  // tests never touch real memory budgets
        let fakes = FakeEngineBag()
        await pool.setEngineFactory { _, _ in fakes.make() }

        try await pool.activate(directory: URL(fileURLWithPath: "/tmp/a"), modelID: "a", diskBytes: 100)
        try await pool.activate(directory: URL(fileURLWithPath: "/tmp/b"), modelID: "b", diskBytes: 100)

        let residents = await pool.residentModelIDs
        XCTAssertEqual(Set(residents), ["a", "b"], "both models stay resident (warm)")
        XCTAssertEqual(fakes.engines.count, 2)
        // Only one load per model — no redundant reloads.
        for engine in fakes.engines {
            XCTAssertEqual(engine.loadCount, 1)
        }
        // Reactivating a resident never creates a second engine.
        try await pool.activate(directory: URL(fileURLWithPath: "/tmp/a"), modelID: "a", diskBytes: 100)
        XCTAssertEqual(fakes.engines.count, 2, "warm switch must not reload")
        for engine in fakes.engines {
            XCTAssertEqual(engine.loadCount, 1)
        }
    }

    func testCapEvictsLRUIdleResident() async throws {
        let pool = EnginePool(maxResident: 2)
        await pool.setAdmitLoad { _ in }
        let fakes = FakeEngineBag()
        await pool.setEngineFactory { _, _ in fakes.make() }

        try await pool.activate(directory: URL(fileURLWithPath: "/tmp/a"), modelID: "a", diskBytes: 100)
        try await Task.sleep(for: .milliseconds(20))  // distinct LRU stamps
        try await pool.activate(directory: URL(fileURLWithPath: "/tmp/b"), modelID: "b", diskBytes: 100)
        try await Task.sleep(for: .milliseconds(20))
        try await pool.activate(directory: URL(fileURLWithPath: "/tmp/c"), modelID: "c", diskBytes: 100)

        let residents = await pool.residentModelIDs
        XCTAssertEqual(Set(residents), ["b", "c"],
                       "the oldest idle resident (a) is evicted; active b/c remain")
        // The evicted engine was unloaded.
        XCTAssertTrue(fakes.engines[0].unloaded, "evicted engine must be unloaded")
    }

    func testAdmissionFailureBlocksLoadEvenWhenCapAllows() async {
        let pool = EnginePool(maxResident: 4)
        await pool.setAdmitLoad { _ in throw MemoryAdvisor.AdmissionError.thermalCritical }
        await pool.setEngineFactory { _, _ in FakeLLMEngine() }

        do {
            try await pool.activate(directory: URL(fileURLWithPath: "/tmp/x"), modelID: "x", diskBytes: 100)
            XCTFail("expected admission failure")
        } catch {
            // MemoryAdvisor.AdmissionError.thermalCritical propagated — the
            // safety stop is never bypassed by the pool.
        }
        let residents = await pool.residentModelIDs
        XCTAssertTrue(residents.isEmpty)
    }

    func testStreamRequiresActiveEngine() async {
        let pool = EnginePool()
        do {
            _ = try await pool.stream(adding: [], maxTokens: nil, temperature: nil)
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertTrue(error is EngineError)
        }
    }

    func testUnloadActiveKeepsOtherResidents() async throws {
        let pool = EnginePool(maxResident: 3)
        await pool.setAdmitLoad { _ in }
        let fakes = FakeEngineBag()
        await pool.setEngineFactory { _, _ in fakes.make() }

        try await pool.activate(directory: URL(fileURLWithPath: "/tmp/a"), modelID: "a", diskBytes: 100)
        try await pool.activate(directory: URL(fileURLWithPath: "/tmp/b"), modelID: "b", diskBytes: 100)
        await pool.unloadActive()

        let residents = await pool.residentModelIDs
        XCTAssertEqual(residents, ["a"], "only the active model (b) unloads")
    }
}

/// Tracks every engine the pool's factory produces.
private final class FakeEngineBag: @unchecked Sendable {
    private let lock = NSLock()
    private var _engines: [FakeLLMEngine] = []

    var engines: [FakeLLMEngine] {
        lock.lock(); defer { lock.unlock() }
        return _engines
    }

    func make() -> FakeLLMEngine {
        let engine = FakeLLMEngine()
        engine.enqueue(.empty)
        lock.lock()
        _engines.append(engine)
        lock.unlock()
        return engine
    }
}

// MARK: - GGUF engine planning

final class GGUFPlannerTests: XCTestCase {

    func testSelectGGUFPicksALargestFile() {
        XCTAssertEqual(
            GGUFEngine.Planner.selectGGUF(named: ["README.md", "model-q4.gguf", "model-q8.gguf"]),
            "model-q8.gguf")
        XCTAssertEqual(
            GGUFEngine.Planner.selectGGUF(named: ["only.gguf"]), "only.gguf")
        XCTAssertNil(GGUFEngine.Planner.selectGGUF(named: ["config.json", "model.safetensors"]))
    }

    func testServerArgumentsAreLoopbackOnly() {
        let args = GGUFEngine.Planner.serverArguments(modelPath: "/m/x.gguf", port: 8123)
        XCTAssertEqual(args[0], "--model")
        XCTAssertEqual(args[1], "/m/x.gguf")
        // Host must be loopback — the model server never listens externally.
        let hostIndex = args.firstIndex(of: "--host")
        XCTAssertEqual(args[hostIndex! + 1], "127.0.0.1")
        let portIndex = args.firstIndex(of: "--port")
        XCTAssertEqual(args[portIndex! + 1], "8123")
    }

    func testHealthDetection() {
        XCTAssertTrue(GGUFEngine.Planner.isHealthy(responseBody: "{\"object\":\"list\",\"data\":[]}"))
        XCTAssertTrue(GGUFEngine.Planner.isHealthy(responseBody: "{\"alias\":\"beetcode\"}"))
        XCTAssertFalse(GGUFEngine.Planner.isHealthy(responseBody: ""))
    }

    func testContextSizeClamping() {
        // Sanity ceiling only: 4 K floor, 256 K ceiling — the RAM-aware
        // choice happens in chooseContextSize before launch (tested below).
        XCTAssertEqual(GGUFEngine.Planner.clampContextSize(8_192), 8_192)
        XCTAssertEqual(GGUFEngine.Planner.clampContextSize(1_000_000), 262_144)
        XCTAssertEqual(GGUFEngine.Planner.clampContextSize(100), 4_096)
        // The default launch keeps 8 K.
        let args = GGUFEngine.Planner.serverArguments(modelPath: "/m.gguf", port: 1)
        XCTAssertTrue(args.contains("--ctx-size"))
        XCTAssertEqual(args[args.firstIndex(of: "--ctx-size")! + 1], "8192")
        // A big-context catalog entry passes through under the sanity
        // ceiling — KV-budget fitting happens earlier, in the load path.
        let big = GGUFEngine.Planner.serverArguments(modelPath: "/m.gguf", port: 1, contextSize: 131_072)
        XCTAssertEqual(big[big.firstIndex(of: "--ctx-size")! + 1], "131072")
    }

    func testServerArgumentsMTPFlagIsOptIn() {
        let plain = GGUFEngine.Planner.serverArguments(modelPath: "/m.gguf", port: 1)
        XCTAssertFalse(plain.contains("--spec-type"))

        let mtp = GGUFEngine.Planner.serverArguments(
            modelPath: "/m.gguf", port: 1, speculativeMTP: true)
        XCTAssertEqual(mtp[mtp.firstIndex(of: "--spec-type")! + 1], "draft-mtp")
        XCTAssertEqual(mtp[mtp.firstIndex(of: "--spec-draft-n-max")! + 1], "2")
    }

    // MARK: KV-aware context admission

    /// Qwen-ish 9 B dims: 36 layers, 4096 embedding, 32 heads, 8 KV heads.
    private func qwenMetadata() -> GGUFMetadata {
        GGUFMetadata(blockCount: 36, embeddingLength: 4096,
                     attentionHeadCount: 32, attentionHeadCountKV: 8)
    }

    func testKVBytesPerToken() {
        // 2 caches × 36 layers × 8 kv-heads × 128 head-dim × 2 bytes (f16).
        XCTAssertEqual(GGUFEngine.Planner.kvBytesPerToken(metadata: qwenMetadata()), 147_456)
        // MHA fallback: no kv-head count → the full head count.
        let mha = GGUFMetadata(blockCount: 36, embeddingLength: 4096, attentionHeadCount: 32)
        XCTAssertEqual(GGUFEngine.Planner.kvBytesPerToken(metadata: mha), 589_824)
        // Missing dims → nil (the caller falls back to the conservative cap).
        XCTAssertNil(GGUFEngine.Planner.kvBytesPerToken(metadata: GGUFMetadata()))
    }

    func testChooseContextRaisesClampWhenRAMAllows() {
        let kv = GGUFEngine.Planner.kvBytesPerToken(metadata: qwenMetadata())!
        // 128 K requested: KV cost ≈ 18 GB — fits easily next to 6 GB
        // weights in a 64 GB budget. The old fixed 32 K clamp is gone.
        let chosen = GGUFEngine.Planner.chooseContextSize(
            requested: 131_072, kvBytesPerToken: kv,
            projectedWeights: 6 << 30, availableBudget: 64 << 30)
        XCTAssertEqual(chosen, 131_072)
    }

    func testChooseContextFitsKVToRemainingBudget() {
        let kv = GGUFEngine.Planner.kvBytesPerToken(metadata: qwenMetadata())!
        let weights: UInt64 = 6 << 30
        // Exactly 8192 tokens of KV headroom after the weights → 8 K, not
        // the requested 128 K.
        let chosen = GGUFEngine.Planner.chooseContextSize(
            requested: 131_072, kvBytesPerToken: kv,
            projectedWeights: weights, availableBudget: weights + UInt64(kv) * 8_192)
        XCTAssertEqual(chosen, 8_192)
    }

    func testChooseContextFallsBackWithoutDimsAndFloorsUnderPressure() {
        // Unsniffable header → conservative 32 K, even with RAM to spare.
        XCTAssertEqual(
            GGUFEngine.Planner.chooseContextSize(
                requested: 131_072, kvBytesPerToken: nil,
                projectedWeights: 0, availableBudget: .max),
            32_768)
        // No budget left after the weights → the 4 K floor (the load was
        // already admitted on the weights).
        let kv = GGUFEngine.Planner.kvBytesPerToken(metadata: qwenMetadata())!
        XCTAssertEqual(
            GGUFEngine.Planner.chooseContextSize(
                requested: 131_072, kvBytesPerToken: kv,
                projectedWeights: 64 << 30, availableBudget: 64 << 30),
            4_096)
    }

    func testJanitorCommandWatchesServerAndParent() {
        let args = GGUFEngine.Planner.janitorCommand(serverPID: 4242, parentPID: 100)
        XCTAssertEqual(args.first, "-c")
        XCTAssertTrue(args[1].contains("kill -0 \"$1\""), "watches the server PID")
        XCTAssertTrue(args[1].contains("kill -0 \"$2\""), "watches the parent PID")
        XCTAssertTrue(args[1].contains("kill \"$1\""), "kills the server when the parent dies")
        XCTAssertEqual(args.suffix(2), ["4242", "100"])
    }

    func testFreePortReturnsUsableLoopbackPort() {
        let port = GGUFEngine.freePort()
        XCTAssertGreaterThan(port, 0)
        XCTAssertLessThan(port, 65_536)
    }

    func testCatalogGGUFEntriesAreWellFormed() {
        let ggufModels = ModelCatalog.bundled.filter { $0.format == .gguf }
        XCTAssertFalse(ggufModels.isEmpty, "GGUF models must be curated")
        for model in ggufModels {
            XCTAssertTrue(model.repo.lowercased().contains("gguf"),
                          "\(model.id): GGUF repo id should point at a GGUF repository")
            XCTAssertGreaterThan(model.diskBytes, 0)
        }
        // Default format is MLX for the historical chat entries (vision
        // sidecars are MLX too but counted by role, not format).
        XCTAssertEqual(ModelCatalog.bundled.filter { $0.format == .mlx && $0.role == .chat }.count, 10)
    }
}

// MARK: - SSE framing

final class SSEFrameParserTests: XCTestCase {

    func testBasicEvent() {
        let parser = SSEFrameParser()
        let events = parser.feed(Data("data: {\"id\":1}\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "{\"id\":1}")
        XCTAssertNil(events[0].name)
    }

    func testMultiLineDataJoinedWithNewlines() {
        let parser = SSEFrameParser()
        let events = parser.feed(Data("data: line1\ndata: line2\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "line1\nline2")
    }

    func testCRLFAndCommentsAndEventNames() {
        let parser = SSEFrameParser()
        let events = parser.feed(Data(": comment\r\nevent: ping\r\ndata: hi\r\n\r\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].name, "ping")
        XCTAssertEqual(events[0].data, "hi")
    }

    func testEventsSurviveArbitraryChunkBoundaries() {
        let parser = SSEFrameParser()
        let full = "data: {\"jsonrpc\":\"2.0\"}\n\n"
        var received: [SSEFrameParser.Event] = []
        // Feed one byte at a time — the harshest possible chunking.
        for byte in full.utf8 {
            received.append(contentsOf: parser.feed(Data([byte])))
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].data, "{\"jsonrpc\":\"2.0\"}")
    }

    func testMultipleEventsInOneChunk() {
        let parser = SSEFrameParser()
        let events = parser.feed(Data("data: a\n\ndata: b\n\n".utf8))
        XCTAssertEqual(events.map(\.data), ["a", "b"])
    }

    func testUnterminatedEventStaysPending() {
        let parser = SSEFrameParser()
        let events = parser.feed(Data("data: partial".utf8))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(parser.hasPendingEvent)
    }
}

// MARK: - OAuth planner (PKCE + request construction)

final class MCPOAuthPlannerTests: XCTestCase {

    func testCodeVerifierIsRFC7636LengthAndCharset() {
        let verifier = MCPOAuthPlanner.makeCodeVerifier()
        XCTAssertEqual(verifier.count, 43, "base64url of 32 random bytes = 43 chars")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        // Randomness: two verifiers must differ.
        XCTAssertNotEqual(verifier, MCPOAuthPlanner.makeCodeVerifier())
    }

    func testCodeChallengeIsS256OfVerifier() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = SHA256.hash(data: Data(verifier.utf8))
        let expectedEncoded = Data(expected)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(MCPOAuthPlanner.codeChallenge(for: verifier), expectedEncoded)
        XCTAssertEqual(expectedEncoded.count, 43)
    }

    func testAuthorizationURLCarriesPKCEParams() {
        let metadata = MCPOAuthMetadata(
            authorization_endpoint: "https://auth.example.com/authorize",
            token_endpoint: "https://auth.example.com/token",
            registration_endpoint: nil)
        let url = MCPOAuthPlanner.authorizationURL(
            metadata: metadata, clientID: "cid", redirectURI: "http://127.0.0.1:31280/callback",
            codeVerifier: "verifier", state: "st4te")
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
            .queryItems!.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "cid")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:31280/callback")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["code_challenge"], MCPOAuthPlanner.codeChallenge(for: "verifier"))
        XCTAssertEqual(query["state"], "st4te")
    }

    func testTokenRequestParams() {
        let metadata = MCPOAuthMetadata(
            authorization_endpoint: "", token_endpoint: "https://auth.example.com/token",
            registration_endpoint: nil)
        let params = MCPOAuthPlanner.tokenRequestParams(
            metadata: metadata, code: "c0de", codeVerifier: "v",
            clientID: "cid", clientSecret: nil, redirectURI: "http://127.0.0.1:31280/callback")
        XCTAssertEqual(params["grant_type"], "authorization_code")
        XCTAssertEqual(params["code"], "c0de")
        XCTAssertEqual(params["code_verifier"], "v")
        XCTAssertNil(params["client_secret"], "public PKCE clients send no secret")
    }

    func testRefreshParams() {
        let params = MCPOAuthPlanner.refreshRequestParams(
            refreshToken: "rt", clientID: "cid", clientSecret: "s")
        XCTAssertEqual(params["grant_type"], "refresh_token")
        XCTAssertEqual(params["refresh_token"], "rt")
        XCTAssertEqual(params["client_secret"], "s")
    }

    func testRefreshSkew() {
        let now = Date()
        let fresh = MCPOAuthTokens(accessToken: "a", refreshToken: nil, expiresAt: now.addingTimeInterval(3600))
        let expiring = MCPOAuthTokens(accessToken: "a", refreshToken: nil, expiresAt: now.addingTimeInterval(10))
        let noExpiry = MCPOAuthTokens(accessToken: "a", refreshToken: nil, expiresAt: nil)
        XCTAssertFalse(MCPOAuthPlanner.shouldRefresh(tokens: fresh, now: now))
        XCTAssertTrue(MCPOAuthPlanner.shouldRefresh(tokens: expiring, now: now))
        XCTAssertFalse(MCPOAuthPlanner.shouldRefresh(tokens: noExpiry, now: now))
    }

    func testDiscoveryURLsCoverWellKnownPaths() {
        let urls = MCPOAuthPlanner.discoveryURLs(for: URL(string: "https://mcp.example.com/v1")!)
        let strings = urls.map(\.absoluteString)
        XCTAssertTrue(strings.contains("https://mcp.example.com/.well-known/oauth-authorization-server"))
        XCTAssertTrue(strings.contains("https://mcp.example.com/.well-known/oauth-protected-resource"))
        XCTAssertEqual(urls.count, 2, "https servers only probe https")
    }

    func testDiscoveryURLsProbeHTTPForLocalServers() {
        let urls = MCPOAuthPlanner.discoveryURLs(for: URL(string: "http://localhost:9000")!)
        XCTAssertTrue(urls.contains { $0.absoluteString.hasPrefix("http://localhost") })
    }

    func testFormEncodingEscapesAndOrders() {
        let encoded = MCPOAuthProvider.formEncode(["b": "2 2", "a": "1&x"])
        XCTAssertEqual(encoded, "a=1%26x&b=2%202")
    }
}

// MARK: - MCP config transport routing

final class MCPServerConfigTransportTests: XCTestCase {

    func testCommandEntriesRouteToStdio() {
        let config = MCPServerConfig(command: "/usr/bin/env", args: [], env: [:])
        XCTAssertEqual(config.transport, .stdio)
    }

    func testURLEntriesRouteToHTTP() {
        var config = MCPServerConfig()
        config.url = "https://mcp.example.com/v1"
        XCTAssertEqual(config.transport, .http)
    }

    func testCommandWinsWhenBothPresent() {
        var config = MCPServerConfig(command: "/usr/bin/env", args: [], env: [:])
        config.url = "https://mcp.example.com/v1"
        XCTAssertEqual(config.transport, .stdio)
    }

    func testConfigLoadRejectsEntriesWithNeitherCommandNorURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent(".beetcode/mcp.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Decode a raw entry: empty object = neither command nor url.
        try Data("{\"mcpServers\":{\"broken\":{}}}".utf8).write(to: configURL)
        let (servers, errors) = MCPConfig.load(workspaceRoot: dir, includeOpenCode: false, includeWorkspace: true)
        XCTAssertTrue(servers.isEmpty)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("broken"))
    }

    func testConfigLoadAcceptsURLEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent(".beetcode/mcp.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"mcpServers\":{\"remote\":{\"url\":\"https://mcp.example.com/v1\"}}}".utf8)
            .write(to: configURL)
        let (servers, errors) = MCPConfig.load(workspaceRoot: dir, includeOpenCode: false, includeWorkspace: true)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers["remote"]?.transport, .http)
    }
}

// MARK: - ModelStore GGUF detection

@MainActor
final class ModelStoreGGUFTests: XCTestCase {

    func testGGUFDirectoryIsLoadableWithoutConfigJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            ModelStore.shared.overrideModelsDir = nil
            try? FileManager.default.removeItem(at: dir)
        }
        ModelStore.shared.overrideModelsDir = dir

        let modelDir = dir.appendingPathComponent("gguf-model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: modelDir.appendingPathComponent("model-q4.gguf"))

        let installed = InstalledModel(
            id: "gguf-model", repo: "test/repo", addedAt: Date(), sizeBytes: 4)

        XCTAssertTrue(ModelStore.shared.hasConfiguration(installed),
                      "a .gguf file alone makes the model loadable (no config.json)")
        XCTAssertEqual(ModelStore.shared.detectedFormat(installed), .gguf)
    }

    func testIncompleteGGUFStillBlocksLoading() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            ModelStore.shared.overrideModelsDir = nil
            try? FileManager.default.removeItem(at: dir)
        }
        ModelStore.shared.overrideModelsDir = dir

        let modelDir = dir.appendingPathComponent("gguf-model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: modelDir.appendingPathComponent("model.gguf.incomplete"))

        let installed = InstalledModel(
            id: "gguf-model", repo: "test/repo", addedAt: Date(), sizeBytes: 4)
        XCTAssertFalse(ModelStore.shared.hasConfiguration(installed))
    }

    func testMLXDirectoryStillRequiresConfigAndWeights() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            ModelStore.shared.overrideModelsDir = nil
            try? FileManager.default.removeItem(at: dir)
        }
        ModelStore.shared.overrideModelsDir = dir

        let modelDir = dir.appendingPathComponent("mlx-model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))
        try Data("w".utf8).write(to: modelDir.appendingPathComponent("model.safetensors"))

        let installed = InstalledModel(
            id: "mlx-model", repo: "test/repo", addedAt: Date(), sizeBytes: 4)
        XCTAssertTrue(ModelStore.shared.hasConfiguration(installed))
        XCTAssertEqual(ModelStore.shared.detectedFormat(installed), .mlx)
    }
}

// MARK: - EngineRouter pool routing

final class EngineRouterPoolTests: XCTestCase {

    func testPooledRouterKeepsPreviousModelResidentOnSwitch() async throws {
        let pool = EnginePool(maxResident: 3)
        await pool.setAdmitLoad { _ in }
        let bag = FakeEngineBag()
        await pool.setEngineFactory { _, _ in bag.make() }
        let router = EngineRouter(local: FakeLLMEngine(), pool: pool)

        try await router.load(directory: URL(fileURLWithPath: "/tmp/a"), modelID: "a", diskBytes: 100)
        try await router.load(directory: URL(fileURLWithPath: "/tmp/b"), modelID: "b", diskBytes: 100)

        let residents = await pool.residentModelIDs
        XCTAssertEqual(Set(residents), ["a", "b"],
                       "multi-resident: switching models must NOT unload the previous one")
    }

    func testLegacyRouterStillUnloadsOnLoad() async throws {
        // No pool → the historical single-resident behavior is preserved for
        // every existing test double and CLI path.
        let fake = FakeLLMEngine()
        let router = EngineRouter(local: fake)
        XCTAssertNil(router.enginePool)
        try await router.load(directory: URL(fileURLWithPath: "/tmp/a"), modelID: "a", diskBytes: 100)
        let loaded = await router.loadedModelID
        XCTAssertEqual(loaded, "a")
    }

    func testFormatAwareLoadReachesTheFactory() async throws {
        let pool = EnginePool(maxResident: 2)
        await pool.setAdmitLoad { _ in }
        let seenFormats = FormatRecorder()
        await pool.setEngineFactory { format, _ in
            seenFormats.record(format)
            let engine = FakeLLMEngine()
            engine.enqueue(.empty)
            return engine
        }
        let router = EngineRouter(local: FakeLLMEngine(), pool: pool)
        try await router.load(directory: URL(fileURLWithPath: "/tmp/g"), modelID: "g", diskBytes: 100, format: .gguf)
        XCTAssertEqual(seenFormats.all, [.gguf])
    }

    // MARK: Effective context window plumbing

    func testPooledRouterSurfacesEngineReportedContextWindow() async throws {
        // The GGUF engine fits the server ctx to RAM (smaller than the
        // catalog window); the router must surface THAT number so the agent
        // loop compacts before llama-server hard-errors.
        let pool = EnginePool(maxResident: 2)
        await pool.setAdmitLoad { _ in }
        await pool.setEngineFactory { _, _ in
            let engine = FakeLLMEngine()
            engine.stubbedContextWindow = 19_712
            return engine
        }
        let router = EngineRouter(local: FakeLLMEngine(), pool: pool)
        try await router.load(directory: URL(fileURLWithPath: "/tmp/g"), modelID: "g", diskBytes: 100, format: .gguf)
        let window = await router.effectiveContextWindow
        XCTAssertEqual(window, 19_712)
    }

    func testRouterContextWindowFallsBackToNilWhenEngineDoesNotKnow() async throws {
        // Engines that size context themselves (MLX, remote, plain fakes)
        // report nil — the caller then uses the catalog window.
        let router = EngineRouter(local: FakeLLMEngine())
        try await router.load(directory: URL(fileURLWithPath: "/tmp/a"), modelID: "a", diskBytes: 100)
        let window = await router.effectiveContextWindow
        XCTAssertNil(window)
    }
}

private final class FormatRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var formats: [CatalogModel.Format] = []
    func record(_ format: CatalogModel.Format) {
        lock.lock(); formats.append(format); lock.unlock()
    }
    var all: [CatalogModel.Format] {
        lock.lock(); defer { lock.unlock() }
        return formats
    }
}

// MARK: - GGUF metadata sniffing

final class GGUFMetadataTests: XCTestCase {

    private enum Value {
        case string(String)
        case uint32(UInt32)
        case uint64(UInt64)
        case stringArray([String])
        case float32Array(Int)  // element count; contents don't matter
    }

    /// Builds a minimal GGUF v3 header: magic, version, tensor_count 0,
    /// then the given metadata key-value pairs (little-endian).
    private func header(_ kvs: [(String, Value)]) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u64(_ v: UInt64) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 8)) }
        func str(_ s: String) { u64(UInt64(s.utf8.count)); data.append(contentsOf: s.utf8) }

        u32(0x46554747)  // "GGUF"
        u32(3)           // version
        u64(0)           // tensor_count
        u64(UInt64(kvs.count))
        for (key, value) in kvs {
            str(key)
            switch value {
            case .string(let s):
                u32(8); str(s)
            case .uint32(let v):
                u32(4); u32(v)
            case .uint64(let v):
                u32(10); u64(v)
            case .stringArray(let elements):
                u32(9); u32(8); u64(UInt64(elements.count))
                for element in elements { str(element) }
            case .float32Array(let count):
                u32(9); u32(6); u64(UInt64(count))
                for _ in 0..<count { u32(0) }
            }
        }
        return data
    }

    func testParsesArchitectureContextLengthAndName() {
        // context_length arrives BEFORE general.architecture on purpose —
        // resolution must happen after all keys are collected. A second
        // architecture's context_length must not win over the matching one.
        let data = header([
            ("qwen3.context_length", .uint32(131_072)),
            ("llama.context_length", .uint32(8_192)),
            ("general.architecture", .string("qwen3")),
            ("general.name", .string("Test Model")),
            ("tokenizer.ggml.tokens", .stringArray(["a", "bb", "ccc"])),
            ("some.floats", .float32Array(3)),
        ])
        let metadata = GGUFMetadata.parse(data)
        XCTAssertEqual(metadata?.architecture, "qwen3")
        XCTAssertEqual(metadata?.contextLength, 131_072)
        XCTAssertEqual(metadata?.modelName, "Test Model")
    }

    func testSingleContextLengthCandidateResolvesWithoutArchitecture() {
        let data = header([
            ("mystery.context_length", .uint64(4_096)),
        ])
        let metadata = GGUFMetadata.parse(data)
        XCTAssertNil(metadata?.architecture)
        XCTAssertEqual(metadata?.contextLength, 4_096)
    }

    func testAmbiguousContextLengthCandidatesResolveToNil() {
        let data = header([
            ("a.context_length", .uint32(1_024)),
            ("b.context_length", .uint32(2_048)),
        ])
        XCTAssertNil(GGUFMetadata.parse(data)?.contextLength)
    }

    func testMTPLayerCountDrivesSupportsDraftMTP() {
        // Qwythos-style header: one nextn predictor layer on a qwen35 arch.
        let withMTP = GGUFMetadata.parse(header([
            ("qwen35.nextn_predict_layers", .uint32(1)),
            ("general.architecture", .string("qwen35")),
        ]))
        XCTAssertEqual(withMTP?.mtpPredictLayers, 1)
        XCTAssertEqual(withMTP?.supportsDraftMTP, true)

        // A plain build without nextn tensors must not trigger the flag.
        let plain = GGUFMetadata.parse(header([
            ("qwen35.context_length", .uint32(262_144)),
            ("general.architecture", .string("qwen35")),
        ]))
        XCTAssertNil(plain?.mtpPredictLayers)
        XCTAssertEqual(plain?.supportsDraftMTP, false)
        // Never-parsed metadata stays off too.
        XCTAssertFalse(GGUFMetadata().supportsDraftMTP)
    }

    func testGarbageAndTruncationNeverCrash() {
        XCTAssertNil(GGUFMetadata.parse(Data()))
        XCTAssertNil(GGUFMetadata.parse(Data("not a gguf file".utf8)))
        // Valid magic but the rest of the fixed header is missing.
        XCTAssertNil(GGUFMetadata.parse(header([]).prefix(8)))

        // A well-formed header whose kv section is cut short parses the
        // intact prefix instead of crashing or throwing.
        let full = header([
            ("general.architecture", .string("qwen3")),
            ("qwen3.context_length", .uint32(131_072)),
            ("general.name", .string("Test Model")),
        ])
        // 24-byte fixed header + one complete kv pair
        // (8+20 key, 4 type, 8+5 string value); the second pair is cut off.
        let cutAfterArchitecture = full.prefix(24 + 45)
        let partial = GGUFMetadata.parse(Data(cutAfterArchitecture))
        XCTAssertEqual(partial?.architecture, "qwen3")
        XCTAssertNil(partial?.contextLength)
    }
}
