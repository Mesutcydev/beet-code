import XCTest
@testable import BeetCode

/// ForgeCache release gate: caches are disposable and content-addressed;
/// deleting them must never lose project, conversation, or capsule data.
final class CacheTests: XCTestCase {

    private var temp: TempWorkspace!

    override func setUpWithError() throws {
        temp = TempWorkspace()
        // Isolate every shared cache store from the developer's real dirs.
        TaskCapsuleStore.shared.overrideDirectory = temp.url(for: "Capsules")
        RepoSummaryCache.shared.overrideDirectory = temp.url(for: "Summaries")
    }

    override func tearDownWithError() throws {
        TaskCapsuleStore.shared.overrideDirectory = nil
        RepoSummaryCache.shared.overrideDirectory = nil
        temp = nil
    }

    private func executor(_ tools: [any AgentTool], cache: ToolResultCache) -> ToolExecutor {
        ToolExecutor(tools: tools, context: ToolContext(workspace: temp.workspace), cache: cache)
    }

    // MARK: Content identity

    func testContentDigestIsStableAndSensitive() throws {
        let a = ContentDigest.sha256Hex("hello world")
        let b = ContentDigest.sha256Hex("hello world")
        let c = ContentDigest.sha256Hex("hello worle")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 64, "SHA-256 hex length")
    }

    func testFileDigestChangesWithContent() throws {
        temp.write("v1", to: "f.txt")
        let first = ContentDigest.fileDigest(at: temp.url(for: "f.txt"))
        temp.write("v2", to: "f.txt")
        let second = ContentDigest.fileDigest(at: temp.url(for: "f.txt"))
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    // MARK: Action cache

    func testReadFileCacheHitsAndInvalidatesOnEdit() async throws {
        temp.write("alpha beta gamma", to: "a.txt")
        let cache = ToolResultCache()
        let ex = executor([ReadFileTool(), WriteFileTool()], cache: cache)

        let call = ParsedToolCall(name: "read_file", arguments: .object(["path": .string("a.txt")]), index: 0)
        let first = await ex.execute(call)
        let second = await ex.execute(call)
        XCTAssertEqual(first.output, second.output)
        let stats = await cache.stats
        XCTAssertEqual(stats.stores, 1, "identical reads must store once")
        XCTAssertEqual(stats.hits, 1, "second read must hit")

        // Edit the file: the content digest changes, the old entry must miss.
        temp.write("alpha beta gamma delta", to: "a.txt")
        let third = await ex.execute(call)
        XCTAssertTrue(third.output.contains("delta"), "stale cached read returned: \(third.output)")
        let after = await cache.stats
        XCTAssertEqual(after.stores, 2)
    }

    func testMutatingToolsAreNeverCached() async throws {
        let cache = ToolResultCache()
        let ex = executor([WriteFileTool()], cache: cache)
        let write = ParsedToolCall(name: "write_file", arguments: .object(["path": .string("n.txt"), "content": .string("x")]), index: 0)
        _ = await ex.execute(write)
        let stats = await cache.stats
        XCTAssertEqual(stats.stores, 0, "write_file must never be cached")
    }

    func testCachedReadStillEnforcesWriteAfterRead() async throws {
        temp.write("content", to: "r.txt")
        let cache = ToolResultCache()
        let ex = executor([ReadFileTool(), WriteFileTool()], cache: cache)
        let read = ParsedToolCall(name: "read_file", arguments: .object(["path": .string("r.txt")]), index: 0)
        _ = await ex.execute(read)  // store
        _ = await ex.execute(read)  // hit — side effects must still noteRead

        let write = ParsedToolCall(name: "write_file", arguments: .object(["path": .string("r.txt"), "content": .string("new")]), index: 0)
        let outcome = await ex.execute(write)
        XCTAssertFalse(outcome.failed, "cached read must still satisfy write-after-read: \(outcome.output)")
    }

    func testShortLivedEntryExpires() async throws {
        let cache = ToolResultCache()
        let ex = executor([ListDirectoryTool()], cache: cache)
        let call = ParsedToolCall(name: "list_directory", arguments: .object(["path": .string(".")]), index: 0)
        _ = await ex.execute(call)
        let stats = await cache.stats
        XCTAssertEqual(stats.stores, 1)
        // 2s TTL: within TTL it hits, after it expires it must recompute.
        _ = await ex.execute(call)
        let during = await cache.stats
        XCTAssertEqual(during.hits, 1)
        try await Task.sleep(for: .seconds(2.2))
        _ = await ex.execute(call)
        let after = await cache.stats
        XCTAssertEqual(after.stores, 2, "expired entry must be recomputed")
    }

    func testActionFingerprintChangesWithArguments() async throws {
        temp.write("line1\nline2\nline3", to: "l.txt")
        let cache = ToolResultCache()
        let ex = executor([ReadFileTool()], cache: cache)
        let one = ParsedToolCall(name: "read_file", arguments: .object(["path": .string("l.txt"), "limit": .number(1)]), index: 0)
        let two = ParsedToolCall(name: "read_file", arguments: .object(["path": .string("l.txt"), "limit": .number(2)]), index: 0)
        _ = await ex.execute(one)
        _ = await ex.execute(two)
        let stats = await cache.stats
        XCTAssertEqual(stats.stores, 2, "different arguments are different cache entries")
    }

    func testEvictionRespectsByteBudget() async throws {
        let cache = ToolResultCache(maxBytes: 256, maxEntries: 1000)
        var keys: [ActionFingerprint] = []
        for index in 0..<8 {
            let key = ActionFingerprint(
                toolID: "t", toolVersion: "1",
                canonicalArgumentsHash: "a\(index)",
                workspaceSnapshotHash: "w", inputContentHashes: [])
            keys.append(key)
            let output = String(repeating: "x", count: 100)
            await cache.store(ToolExecutor.Outcome(output: output, failed: false), for: key, ttl: nil)
        }
        let count = await cache.entryCount
        let stats = await cache.stats
        XCTAssertLessThanOrEqual(count, 3, "byte budget must evict: \(count)")
        XCTAssertGreaterThan(stats.evictions, 0)
    }

    // MARK: Repo summary cache

    func testSummaryCacheReusesAndRecomputes() throws {
        temp.write("import Foundation\nstruct A {}\n", to: "Sources/A.swift")
        temp.makeDirectory("Sources")
        _ = RepoIndexer.build(root: temp.url)
        let first = RepoSummaryCache.shared.stats
        XCTAssertGreaterThan(first.misses, 0)

        _ = RepoIndexer.build(root: temp.url)
        let second = RepoSummaryCache.shared.stats
        XCTAssertEqual(second.misses, first.misses, "unchanged files must reuse cached summaries")
        XCTAssertGreaterThan(second.hits, first.hits)

        temp.write("import Foundation\nstruct B {}\n", to: "Sources/A.swift")
        _ = RepoIndexer.build(root: temp.url)
        let third = RepoSummaryCache.shared.stats
        XCTAssertGreaterThan(third.misses, second.misses, "edited file must recompute")
    }

    func testSummaryCacheSurvivesMemoryClearAndDiskReuse() throws {
        temp.write("func main() {}\n", to: "main.swift")
        let before = RepoSummaryCache.shared.stats
        _ = RepoIndexer.build(root: temp.url)
        let afterFirst = RepoSummaryCache.shared.stats
        XCTAssertGreaterThan(afterFirst.misses, before.misses)

        RepoSummaryCache.shared.clearMemory()
        _ = RepoIndexer.build(root: temp.url)
        let afterSecond = RepoSummaryCache.shared.stats
        XCTAssertEqual(afterSecond.misses, afterFirst.misses, "disk-backed summaries must survive memory clear")
        XCTAssertGreaterThan(afterSecond.hits, afterFirst.hits)
    }

    func testDeletingCacheDirectoryIsSafe() throws {
        temp.write("import Foundation\nstruct C {}\n", to: "c.swift")
        let before = RepoIndexer.build(root: temp.url)
        XCTAssertNotNil(before.entries.first { $0.path == "c.swift" }?.summary)

        // Nuke the ENTIRE cache tree — the index must rebuild from source.
        let cacheDir = RepoSummaryCache.shared.overrideDirectory!
        try? FileManager.default.removeItem(at: cacheDir)
        let after = RepoIndexer.build(root: temp.url)
        let summary = after.entries.first { $0.path == "c.swift" }?.summary
        XCTAssertNotNil(summary, "cache deletion must not break indexing")
        XCTAssertEqual(summary, before.entries.first { $0.path == "c.swift" }?.summary)
    }

    // MARK: Capsules (durable, never cache)

    func testCapsuleRoundTrip() throws {
        let capsule = AgentTaskCapsule(
            taskID: UUID(),
            workspaceID: "ws",
            epochID: UUID(),
            objective: "refactor auth",
            changedFiles: ["wrote Auth.swift (12 lines)"],
            unresolvedDiagnostics: [],
            completedChecks: ["Build completed with no diagnostics."],
            lastUserInstruction: "go",
            createdAt: Date(),
            updatedAt: Date())
        TaskCapsuleStore.shared.save(capsule)
        let loaded = TaskCapsuleStore.shared.load(taskID: capsule.taskID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.objective, "refactor auth")
        XCTAssertEqual(loaded?.changedFiles, capsule.changedFiles)
        TaskCapsuleStore.shared.delete(taskID: capsule.taskID)
        XCTAssertNil(TaskCapsuleStore.shared.load(taskID: capsule.taskID))
    }

    func testCapsuleSurvivesCacheDeletion() throws {
        let capsule = AgentTaskCapsule(
            taskID: UUID(),
            workspaceID: "ws2",
            epochID: UUID(),
            objective: "fix build",
            changedFiles: [],
            unresolvedDiagnostics: ["error: missing symbol"],
            completedChecks: [],
            lastUserInstruction: "fix it",
            createdAt: Date(),
            updatedAt: Date())
        TaskCapsuleStore.shared.save(capsule)
        // Delete the cache tree (summary cache lives inside it); the capsule
        // lives in Application Support and must be untouched.
        let cacheDir = RepoSummaryCache.shared.overrideDirectory!
        try? FileManager.default.removeItem(at: cacheDir)
        let loaded = TaskCapsuleStore.shared.load(taskID: capsule.taskID)
        XCTAssertNotNil(loaded, "deleting caches must never delete agent progress")
    }

    // MARK: Budget governor

    func testBudgetGovernorReserveAndCaps() {
        let gib: UInt64 = 1_073_741_824
        let mib: UInt64 = 1_048_576
        let comfortable = CacheBudgetGovernor.calculateBudget(availableBytes: 16 * gib)
        XCTAssertEqual(comfortable.kvBudgetBytes, 768 * mib, "KV capped at 768 MB")
        XCTAssertEqual(comfortable.hotObjectBudgetBytes, 256 * mib)

        let tight = CacheBudgetGovernor.calculateBudget(availableBytes: 1 * gib)
        XCTAssertEqual(tight.kvBudgetBytes, 128 * mib, "constrained floor")
        XCTAssertEqual(tight.hotObjectBudgetBytes, 64 * mib)
        XCTAssertGreaterThan(comfortable.reserveBytes, tight.reserveBytes)
    }
}
