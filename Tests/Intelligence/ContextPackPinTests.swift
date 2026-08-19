import Foundation
import XCTest
@testable import BeetCode

/// Phase 18 — Context pack pinning: persistence scoping + retrieval
/// reweighting under an unchanged budget cap.
final class ContextPackPinTests: XCTestCase {

    private func makePinStore() throws -> ContextPackPinStore {
        try ContextPackPinStore(store: SQLiteStore(
            url: URL(fileURLWithPath: "/tmp/x"), inMemory: true))
    }

    // MARK: Store scoping

    func testWorkspacePinsApplyToAllSessions() throws {
        let store = try makePinStore()
        try store.pin(.security, scope: .workspace, workspaceID: "w1")
        XCTAssertEqual(try store.pinnedPacks(workspaceID: "w1", sessionID: nil), [.security])
        XCTAssertEqual(try store.pinnedPacks(workspaceID: "w1", sessionID: UUID()), [.security])
        // Other workspaces see nothing.
        XCTAssertTrue(try store.pinnedPacks(workspaceID: "w2", sessionID: nil).isEmpty)
    }

    func testSessionPinsAreIsolated() throws {
        let store = try makePinStore()
        let sessionA = UUID()
        let sessionB = UUID()
        try store.pin(.testing, scope: .session, workspaceID: "w1", sessionID: sessionA)
        XCTAssertEqual(try store.pinnedPacks(workspaceID: "w1", sessionID: sessionA), [.testing])
        XCTAssertTrue(try store.pinnedPacks(workspaceID: "w1", sessionID: sessionB).isEmpty)
        XCTAssertTrue(try store.pinnedPacks(workspaceID: "w1", sessionID: nil).isEmpty)
    }

    func testUnpinAndRepinIdempotent() throws {
        let store = try makePinStore()
        try store.pin(.security, scope: .workspace, workspaceID: "w1")
        try store.pin(.security, scope: .workspace, workspaceID: "w1") // no duplicate
        XCTAssertEqual(try store.pinnedPacks(workspaceID: "w1", sessionID: nil).count, 1)
        try store.unpin(.security, scope: .workspace, workspaceID: "w1")
        XCTAssertTrue(try store.pinnedPacks(workspaceID: "w1", sessionID: nil).isEmpty)
    }

    // MARK: Retrieval reweighting

    private func makeCompiler(
        knowledge: KnowledgeStore
    ) -> ContextCompiler {
        let graph = try! SymbolGraph(store: SQLiteStore(
            url: URL(fileURLWithPath: "/tmp/g"), inMemory: true))
        return ContextCompiler(
            graph: graph, knowledge: knowledge,
            capsuleProvider: {
                ProjectCapsule(
                    projectName: "Demo", languages: [], structure: [],
                    hubSymbols: [], branch: nil, commit: nil,
                    fileCount: 0, symbolCount: 0, edgeCount: 0,
                    snapshotID: UUID(), generatedAt: Date(), staleKnowledgeCount: 0)
            })
    }

    private func record(
        _ kind: KnowledgeKind, scope: String, statement: String
    ) -> KnowledgeRecord {
        KnowledgeRecord(
            id: "kn_\(UUID().uuidString.prefix(8))", kind: kind, scope: scope,
            statement: statement, confidence: .verified, freshness: .fresh,
            evidence: [Evidence(path: "a.swift", symbolID: nil, startLine: nil,
                                endLine: nil, contentHash: "h", gitCommit: nil,
                                capturedAt: Date())],
            branchScope: nil, createdAt: Date(), updatedAt: Date())
    }

    private let budget = ContextBudget(
        contextWindowTokens: 100_000, maxOutputTokens: 4_000,
        systemPromptTokens: 2_000, conversationTokens: 1_000,
        safetyMarginTokens: 1_000)

    func testPinBoostsIrrelevantKindAheadOfRelevantUnpinned() throws {
        let knowledge = try KnowledgeStore(store: SQLiteStore(
            url: URL(fileURLWithPath: "/tmp/k"), inMemory: true))
        // Relevant to the task text, unpinned.
        try knowledge.insert(record(.architecture, scope: "RefreshToken",
                                    statement: "RefreshToken flow is layered"))
        // Irrelevant to the task, but security.
        try knowledge.insert(record(.security, scope: "Secrets",
                                    statement: "credentials never touch disk"))

        let compiler = makeCompiler(knowledge: knowledge)
        let task = AgentTask(text: "how does RefreshToken work")

        let unpinned = try compiler.compileContext(task: task, budget: budget)
        let unpinnedFirst = unpinned.items.first { $0.section != .history }
        XCTAssertTrue(unpinnedFirst?.text.contains("RefreshToken") ?? false)

        let pinned = try compiler.compileContext(
            task: task, budget: budget, pinnedPacks: [.security])
        let pinnedFirst = pinned.items.first { $0.section != .history }
        XCTAssertTrue(pinnedFirst?.text.contains("credentials") ?? false,
                      "pinned security record must lead: \(pinnedFirst?.text ?? "none")")
        XCTAssertEqual(pinnedFirst?.whyIncluded, "pinned pack (security)")
    }

    func testPinNeverExceedsBudget() throws {
        let knowledge = try KnowledgeStore(store: SQLiteStore(
            url: URL(fileURLWithPath: "/tmp/k2"), inMemory: true))
        // Many pinned records, collectively larger than the knowledge budget.
        for index in 0..<50 {
            try knowledge.insert(record(
                .security, scope: "Secret\(index)",
                statement: String(repeating: "credential handling rule \(index) ", count: 20)))
        }
        let compiler = makeCompiler(knowledge: knowledge)
        let pinned = try compiler.compileContext(
            task: AgentTask(text: "anything"), budget: budget,
            pinnedPacks: [.security])
        let knowledgeTokens = pinned.items
            .filter { $0.section == .knowledge }
            .reduce(0) { $0 + $1.estimatedTokens }
        XCTAssertLessThanOrEqual(knowledgeTokens, budget.allocation().knowledge,
                                 "pinned packs must not force prompt dumping")
        XCTAssertFalse(pinned.items.isEmpty) // but they DO get priority
    }
}
