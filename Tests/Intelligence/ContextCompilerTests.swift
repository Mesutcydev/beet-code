import Foundation
import XCTest
@testable import BeetCode

/// Phase 12 — Context Compiler. Packet contents must trace to real indexed
/// fixtures; budgets are enforced; compilation is deterministic.
final class ContextCompilerTests: XCTestCase {

    private let authFile = """
    import Foundation
    final class AuthService {
        func refreshToken() { persistToken() }
        private func persistToken() {}
    }
    """

    private let callerFile = """
    import Foundation
    struct LoginFlow {
        func begin() { AuthService().refreshToken() }
    }
    """

    private func makeCompiler(
        knowledge: KnowledgeStore? = nil
    ) throws -> (ContextCompiler, SymbolGraph) {
        let graph = try SymbolGraph(store: SQLiteStore(
            url: URL(fileURLWithPath: ":memory:"), inMemory: true))
        let search = try SearchIndex(store: SQLiteStore(
            url: URL(fileURLWithPath: ":memory:"), inMemory: true))
        for (source, path) in [(authFile, "Core/AuthService.swift"),
                               (callerFile, "App/LoginFlow.swift")] {
            let file = SourceFile(path: path, content: source,
                                  contentHash: ContentDigest.sha256Hex(source))
            let parsed = ParserRegistry.parse(file: file)!
            try graph.upsertFile(parsed)
            try search.indexFile(parsed, content: source)
        }
        let snapshot = WorkspaceSnapshot(
            snapshotID: UUID(),
            identity: WorkspaceIdentity(
                workspaceID: "wks_test", canonicalPath: "/tmp/x",
                displayName: "FixtureApp", git: nil),
            git: nil, files: [:], createdAt: Date())
        let compiler = ContextCompiler(
            graph: graph, search: search, knowledge: knowledge,
            capsuleProvider: {
                try CapsuleGenerator.generate(
                    identity: WorkspaceIdentity(
                        workspaceID: "wks_test", canonicalPath: "/tmp/x",
                        displayName: "FixtureApp", git: nil),
                    snapshot: snapshot, graph: graph)
            },
            sourceLoader: { path, start, end in
                let source = path.contains("AuthService") ? self.authFile : self.callerFile
                let lines = source.split(separator: "\n").map(String.init)
                guard start >= 1, end <= lines.count else { return nil }
                return lines[(start - 1)..<end].joined(separator: "\n")
            })
        return (compiler, graph)
    }

    private let budget = ContextBudget(
        contextWindowTokens: 32_768, maxOutputTokens: 2_048,
        systemPromptTokens: 2_000, conversationTokens: 4_000,
        safetyMarginTokens: 1_000)

    func testTaskMentioningSymbolPullsItsNeighborhood() throws {
        let (compiler, _) = try makeCompiler()
        let packet = try compiler.compileContext(
            task: AgentTask(text: "Why does AuthService fail to refresh?"),
            budget: budget)
        let names = packet.symbols.map(\.name)
        XCTAssertTrue(names.contains("AuthService"))
        // Graph neighborhood: refreshToken arrives via the contains/calls edges.
        XCTAssertTrue(names.contains("refreshToken"))
        XCTAssertFalse(packet.relationships.isEmpty)
    }

    func testExplicitFileAnchorPrioritizesItsSymbols() throws {
        let (compiler, _) = try makeCompiler()
        let packet = try compiler.compileContext(
            task: AgentTask(text: "refactor", explicitFiles: ["App/LoginFlow.swift"]),
            budget: budget)
        let loginSymbols = packet.symbols.filter { $0.path == "App/LoginFlow.swift" }
        XCTAssertFalse(loginSymbols.isEmpty)
        XCTAssertTrue(loginSymbols.contains { $0.name == "LoginFlow" })
    }

    func testBudgetIsRespected() throws {
        let (compiler, _) = try makeCompiler()
        let tiny = ContextBudget(
            contextWindowTokens: 4_096, maxOutputTokens: 1_024,
            systemPromptTokens: 1_500, conversationTokens: 1_000,
            safetyMarginTokens: 500)
        let packet = try compiler.compileContext(
            task: AgentTask(text: "AuthService refreshToken LoginFlow"),
            budget: tiny)
        XCTAssertLessThanOrEqual(packet.estimatedTokens,
                                 tiny.availableWorkspaceTokens + 800) // capsule ceiling
    }

    func testKnowledgeOrderingAndStaleLabeling() throws {
        let store = try KnowledgeStore(store: SQLiteStore(
            url: URL(fileURLWithPath: ":memory:"), inMemory: true))
        // Fresh decision + stale pitfall.
        try store.insert(KnowledgeRecord(
            id: "kn_fresh", kind: .decision, scope: "AuthService",
            statement: "Refresh tokens rotate on every use.",
            confidence: .verified, freshness: .fresh, evidence: [],
            branchScope: nil, createdAt: Date(), updatedAt: Date()))
        try store.insert(KnowledgeRecord(
            id: "kn_stale", kind: .pitfall, scope: "AuthService",
            statement: "Refresh once looped forever.",
            confidence: .verified, freshness: .stale, evidence: [],
            branchScope: nil, createdAt: Date(), updatedAt: Date()))

        let (compiler, _) = try makeCompiler(knowledge: store)
        let packet = try compiler.compileContext(
            task: AgentTask(text: "AuthService token behavior"),
            budget: budget)

        let fresh = packet.items.first { $0.id == "kn_fresh" }
        XCTAssertNotNil(fresh)
        XCTAssertEqual(fresh?.freshness, "fresh")
        let stale = packet.items.first { $0.id == "kn_stale" }
        XCTAssertNotNil(stale)
        XCTAssertTrue(stale?.text.hasPrefix("STALE") == true)
        // Stale never ranks as trusted knowledge.
        XCTAssertEqual(stale?.section, .history)
    }

    func testDeterministicCompilation() throws {
        let (compiler, _) = try makeCompiler()
        let task = AgentTask(text: "AuthService refreshToken behavior")
        let first = try compiler.compileContext(task: task, budget: budget)
        let second = try compiler.compileContext(task: task, budget: budget)
        XCTAssertEqual(first.symbols.map(\.symbolID), second.symbols.map(\.symbolID))
        XCTAssertEqual(first.relationships, second.relationships)
        XCTAssertEqual(first.items.map(\.id), second.items.map(\.id))
    }

    func testSourceSnippetsComeFromAnchoredSymbols() throws {
        let (compiler, _) = try makeCompiler()
        let packet = try compiler.compileContext(
            task: AgentTask(text: "explain refreshToken", explicitSymbols: ["refreshToken"]),
            budget: budget)
        XCTAssertFalse(packet.sources.isEmpty)
        XCTAssertEqual(packet.sources.first?.path, "Core/AuthService.swift")
        XCTAssertTrue(packet.sources.first?.text.contains("persistToken") == true)
    }

    func testTokenBudgeterArithmetic() {
        let b = ContextBudget(
            contextWindowTokens: 32_000, maxOutputTokens: 2_000,
            systemPromptTokens: 2_000, conversationTokens: 8_000,
            safetyMarginTokens: 1_000)
        XCTAssertEqual(b.availableWorkspaceTokens, 19_000)
        let alloc = b.allocation()
        XCTAssertEqual(alloc.capsule, 800)
        XCTAssertEqual(alloc.knowledge + alloc.graph + alloc.source + alloc.history,
                       19_000 - 800, accuracy: 3) // integer split rounding
        let broke = ContextBudget(
            contextWindowTokens: 4_000, maxOutputTokens: 2_000,
            systemPromptTokens: 2_000, conversationTokens: 1_500,
            safetyMarginTokens: 500)
        XCTAssertEqual(broke.availableWorkspaceTokens, 0)
    }
}
