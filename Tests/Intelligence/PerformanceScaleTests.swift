import Foundation
import XCTest
@testable import BeetCode

/// Phase 20 — Performance + scale evidence. Synthetic repositories of
/// different shapes are generated deterministically, indexed for real, and
/// measured. Results print as a report; assertions guard only against
/// pathological regressions (order-of-magnitude), not machine speed.
final class PerformanceScaleTests: XCTestCase {

    private var retained: [TempWorkspace] = []

    struct Measurements {
        var label: String
        var files: Int
        var fullIndexMs: Int
        var incrementalMs: Int
        var symbolQueryUs: Int
        var callerQueryUs: Int
        var impactQueryUs: Int
        var compileMs: Int
        var storageBytes: Int64
    }

    // MARK: Repo synthesis

    /// A Swift file with a type, two methods, and a cross-file call.
    private func swiftFile(index: Int, callsIndex: Int?) -> String {
        let call = callsIndex.map { "\n    func use() { Worker\($0)().work() }" } ?? ""
        return """
        import Foundation

        final class Worker\(index) {
            func work() {
                helper()
            }

            private func helper() {
            }
        \(call)
        }
        """
    }

    private func makeRepo(files: Int, prefix: String) -> TempWorkspace {
        let ws = TempWorkspace()
        retained.append(ws)
        for index in 0..<files {
            let calls = index > 0 ? index - 1 : nil
            ws.write(swiftFile(index: index, callsIndex: calls),
                     to: "\(prefix)/Module\(index / 50)/Worker\(index).swift")
        }
        return ws
    }

    private func makeEngine(_ ws: TempWorkspace) throws -> (IndexEngine, TempWorkspace) {
        let storeDir = TempWorkspace()
        retained.append(storeDir)
        let snapshotStore = WorkspaceSnapshotStore()
        snapshotStore.overrideDirectory = storeDir.url.appendingPathComponent("snapshots")
        let engine = IndexEngine(
            identity: WorkspaceIdentity.resolve(root: ws.url),
            graph: try SymbolGraph(store: SQLiteStore(
                url: storeDir.url.appendingPathComponent("graph.sqlite"))),
            journal: try InvalidationJournal(store: SQLiteStore(
                url: storeDir.url.appendingPathComponent("metadata.sqlite"))),
            snapshotStore: snapshotStore,
            entityStore: try EntityStore(store: SQLiteStore(
                url: storeDir.url.appendingPathComponent("graph.sqlite"))))
        return (engine, storeDir)
    }

    private func storageSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Measurement harness

    private func measureRepo(
        label: String, ws: TempWorkspace, files: Int,
        touchPath: (Int) -> String = { "Sources/Module\($0 / 50)/Worker\($0).swift" }
    ) async throws -> Measurements {
        var result = Measurements(
            label: label, files: files, fullIndexMs: 0, incrementalMs: 0,
            symbolQueryUs: 0, callerQueryUs: 0, impactQueryUs: 0,
            compileMs: 0, storageBytes: 0)

        let (engine, storeDir) = try makeEngine(ws)

        let fullStart = Date()
        let stats = try await engine.fullIndex()
        result.fullIndexMs = Int(Date().timeIntervalSince(fullStart) * 1000)
        XCTAssertEqual(stats.parsed, files, "\(label): all files parsed")

        // Incremental: touch 1% of files (min 1).
        let touched = max(1, files / 100)
        for index in 0..<touched {
            ws.write(swiftFile(index: index, callsIndex: nil) + "\n// touched\n",
                     to: touchPath(index))
        }
        let incStart = Date()
        let incStats = try await engine.incrementalUpdate()
        result.incrementalMs = Int(Date().timeIntervalSince(incStart) * 1000)
        XCTAssertEqual(incStats.modified, touched)

        let graph = await engine.graphHandle

        func micros(_ body: () throws -> Void) -> Int {
            let start = Date()
            try! body()
            return Int(Date().timeIntervalSince(start) * 1_000_000)
        }

        result.symbolQueryUs = micros { _ = try graph.findSymbols(named: "Worker\(files / 2)") }
        let mid = try graph.findSymbols(named: "Worker\(files / 2)").first!
        result.callerQueryUs = micros { _ = try graph.callers(of: mid.id) }
        result.impactQueryUs = micros { _ = try graph.impactNeighborhood(of: mid.id, depth: 2) }

        let compiler = ContextCompiler(graph: graph, capsuleProvider: {
            ProjectCapsule(
                projectName: label, languages: [("swift", files)], structure: [],
                hubSymbols: [], branch: nil, commit: nil, fileCount: files,
                symbolCount: files * 3, edgeCount: files, snapshotID: UUID(),
                generatedAt: Date(), staleKnowledgeCount: 0)
        })
        let budget = ContextBudget(
            contextWindowTokens: 100_000, maxOutputTokens: 4_000,
            systemPromptTokens: 2_000, conversationTokens: 1_000, safetyMarginTokens: 1_000)
        let compileStart = Date()
        _ = try compiler.compileContext(
            task: AgentTask(text: "how does Worker\(files / 2) work"), budget: budget)
        result.compileMs = Int(Date().timeIntervalSince(compileStart) * 1000)

        result.storageBytes = storageSize(storeDir.url)
        return result
    }

    // MARK: Scale matrix

    func testSmallRepo() async throws {
        let m = try await measureRepo(label: "small", ws: makeRepo(files: 20, prefix: "Sources"), files: 20)
        report(m)
    }

    func testMediumRepo() async throws {
        let m = try await measureRepo(label: "medium", ws: makeRepo(files: 200, prefix: "Sources"), files: 200)
        report(m)
        // Pathological-regression guard: 200 files must index in seconds.
        XCTAssertLessThan(m.fullIndexMs, 20_000)
    }

    func testLargeRepo() async throws {
        let m = try await measureRepo(label: "large", ws: makeRepo(files: 1_000, prefix: "Sources"), files: 1_000)
        report(m)
        XCTAssertLessThan(m.fullIndexMs, 60_000)
        XCTAssertLessThan(m.incrementalMs, m.fullIndexMs,
                          "incremental must beat full re-index")
    }

    func testMonorepoShape() async throws {
        let ws = TempWorkspace()
        retained.append(ws)
        for package in 0..<6 {
            for index in 0..<30 {
                ws.write(swiftFile(index: package * 30 + index,
                                   callsIndex: index > 0 ? package * 30 + index - 1 : nil),
                         to: "Packages/Package\(package)/Sources/Worker\(index).swift")
            }
        }
        let m = try await measureRepo(
            label: "monorepo", ws: ws, files: 180,
            touchPath: { "Packages/Package0/Sources/Worker\($0).swift" })
        report(m)
    }

    func testBranchHeavyRepo() async throws {
        let ws = makeRepo(files: 30, prefix: "Sources")
        let repo = GitRepo(in: ws)
        repo.commitAll(message: "base")
        for branch in 0..<12 {
            repo.run(["checkout", "-q", "-b", "feature-\(branch)"])
            ws.write("// branch \(branch)\n", to: "Notes\(branch).md")
            repo.commitAll(message: "branch \(branch) note")
        }
        repo.run(["checkout", "-q", "main"])
        // Identity and indexing must be unaffected by branch count.
        let (engine, _) = try makeEngine(ws)
        let stats = try await engine.fullIndex()
        XCTAssertEqual(stats.parsed, 30)
        print("[perf] branch-heavy: 12 branches, full index \(stats.durationMs) ms")
    }

    func testGeneratedFilesAreIgnored() async throws {
        let ws = makeRepo(files: 10, prefix: "Sources")
        ws.write(".build/\nGenerated/\n", to: ".gitignore")
        for index in 0..<100 {
            ws.write(swiftFile(index: 1000 + index, callsIndex: nil),
                     to: "Generated/Gen\(index).swift")
        }
        let (engine, _) = try makeEngine(ws)
        let stats = try await engine.fullIndex()
        XCTAssertEqual(stats.parsed, 10,
                       "generated files behind .gitignore must not be indexed")
        print("[perf] generated: 100 ignored files skipped, index \(stats.durationMs) ms")
    }

    func testMultiLanguageRepo() async throws {
        let ws = makeRepo(files: 20, prefix: "Sources")
        for index in 0..<20 {
            ws.write("def worker_\(index)():\n    pass\n", to: "Scripts/w\(index).py")
            ws.write("function worker\(index)() {}\n", to: "Web/w\(index).js")
        }
        let (engine, _) = try makeEngine(ws)
        let stats = try await engine.fullIndex()
        XCTAssertEqual(stats.parsed, 20)
        XCTAssertEqual(stats.skippedUnsupported, 40,
                       "unsupported languages are honestly skipped, not guessed")
        print("[perf] multi-language: 20 swift parsed, 40 unsupported skipped, \(stats.durationMs) ms")
    }

    // MARK: Report

    private func report(_ m: Measurements) {
        print("""
        [perf] \(m.label): files=\(m.files) fullIndex=\(m.fullIndexMs)ms \
        incremental=\(m.incrementalMs)ms symbolQuery=\(m.symbolQueryUs)µs \
        callerQuery=\(m.callerQueryUs)µs impact=\(m.impactQueryUs)µs \
        compile=\(m.compileMs)ms storage=\(m.storageBytes / 1024)KB
        """)
    }
}
