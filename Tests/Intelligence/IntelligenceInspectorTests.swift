import Foundation
import XCTest
@testable import BeetCode

/// Phase 17 — Inspector model assembly. Views are thin; all numbers are
/// asserted here against real stores.
final class IntelligenceInspectorTests: XCTestCase {

    private func makeStores() throws -> (SymbolGraph, KnowledgeStore, EntityStore) {
        let graph = try SymbolGraph(store: SQLiteStore(
            url: URL(fileURLWithPath: "/tmp/x"), inMemory: true))
        let knowledge = try KnowledgeStore(store: SQLiteStore(
            url: URL(fileURLWithPath: "/tmp/y"), inMemory: true))
        let entities = try EntityStore(store: SQLiteStore(
            url: URL(fileURLWithPath: "/tmp/z"), inMemory: true))
        return (graph, knowledge, entities)
    }

    private func record(
        _ kind: KnowledgeKind, scope: String = "s", freshness: FreshnessState = .fresh
    ) -> KnowledgeRecord {
        KnowledgeRecord(
            id: "kn_\(UUID().uuidString.prefix(8))", kind: kind, scope: scope,
            statement: "statement", confidence: .verified, freshness: freshness,
            evidence: [Evidence(path: "a.swift", symbolID: nil, startLine: nil,
                                endLine: nil, contentHash: "h", gitCommit: nil,
                                capturedAt: Date())],
            branchScope: nil, createdAt: Date(), updatedAt: Date())
    }

    // MARK: Status

    func testStatusDerivation() {
        XCTAssertEqual(IntelligenceInspectorBuilder.status(
            lastSnapshotAt: nil, pendingChanges: 0), .unavailable)
        XCTAssertEqual(IntelligenceInspectorBuilder.status(
            lastSnapshotAt: Date(), pendingChanges: 3), .stale)
        XCTAssertEqual(IntelligenceInspectorBuilder.status(
            lastSnapshotAt: Date(), pendingChanges: 0), .fresh)
    }

    // MARK: Domains

    func testDomainsReflectRealStores() throws {
        let (graph, knowledge, entities) = try makeStores()
        let source = SourceFile(path: "Sources/A.swift", content: "struct A { func f() {} }",
                                contentHash: "h")
        try graph.upsertFile(ParserRegistry.parse(file: source)!)

        try knowledge.insert(record(.architecture))
        try knowledge.insert(record(.pitfall, freshness: .stale))
        try knowledge.insert(record(.security))

        try entities.replaceEntities(forFile: "Sources/Auth/LoginView.swift", entities: [
            SemanticEntity(kind: .screen, name: "LoginView",
                           path: "Sources/Auth/LoginView.swift", source: "test"),
        ])
        try entities.replaceEntities(forFile: "Sources/Data/Item.swift", entities: [
            SemanticEntity(kind: .databaseModel, name: "Item",
                           path: "Sources/Data/Item.swift", source: "test"),
            SemanticEntity(kind: .secretReference, name: "API_KEY",
                           path: "Sources/Data/Item.swift", source: "test"),
        ])

        let working = WorkingState(sessionID: UUID(), workspaceID: "w", branch: "main",
                                   objective: "ship", plan: ["[x] a", "[ ] b"],
                                   touchedFiles: ["A.swift"], hypotheses: [],
                                   openQuestions: [], failingTests: [])

        let domains = try IntelligenceInspectorBuilder.domains(
            graph: graph, knowledge: knowledge, entities: entities,
            workingState: working)

        XCTAssertEqual(domains.map(\.name), [
            "Structure", "Architecture", "Logic", "Features", "Data", "Security",
            "Capabilities", "Runtime", "Testing", "Decisions", "Pitfalls", "Current",
        ])

        let byName = Dictionary(uniqueKeysWithValues: domains.map { ($0.name, $0) })
        XCTAssertEqual(byName["Structure"]?.freshness, .fresh)
        XCTAssertTrue(byName["Structure"]?.detail.contains("nodes") ?? false)
        XCTAssertEqual(byName["Architecture"]?.count, 1)
        XCTAssertEqual(byName["Logic"]?.freshness, .unavailable)
        XCTAssertEqual(byName["Features"]?.count, 2) // Auth + Data groupings
        XCTAssertEqual(byName["Data"]?.count, 1)     // 1 databaseModel entity
        XCTAssertEqual(byName["Security"]?.count, 2) // record + secretReference
        XCTAssertEqual(byName["Pitfalls"]?.freshness, .stale)
        XCTAssertEqual(byName["Current"]?.count, 1)  // touchedFiles
        XCTAssertTrue(byName["Current"]?.detail.contains("main") ?? false)
        XCTAssertTrue(byName["Current"]?.detail.contains("1/2 plan") ?? false)
    }

    // MARK: Request breakdown

    func testRequestBreakdown() throws {
        let capsule = ProjectCapsule(
            projectName: "Demo", languages: [("swift", 3)],
            structure: [("Sources", 3)], hubSymbols: [], branch: "main",
            commit: nil, fileCount: 3, symbolCount: 5, edgeCount: 2,
            snapshotID: UUID(), generatedAt: Date(), staleKnowledgeCount: 0)

        let items = [
            ContextItem(section: .architecture, id: "a1", text: "layered design",
                        whyIncluded: "relevant to task", confidence: "verified",
                        freshness: "fresh", estimatedTokens: 205),
            ContextItem(section: .pitfall, id: "p1", text: "avoid x",
                        whyIncluded: "keyword match", confidence: "verified",
                        freshness: "fresh", estimatedTokens: 81),
            ContextItem(section: .symbol, id: "s1", text: "AuthService",
                        whyIncluded: "exact match", confidence: "syntactic",
                        freshness: "fresh", estimatedTokens: 100),
            ContextItem(section: .symbol, id: "s2", text: "SessionManager",
                        whyIncluded: "graph neighbor", confidence: "syntactic",
                        freshness: "fresh", estimatedTokens: 100),
            ContextItem(section: .source, id: "src1", text: "snippet",
                        whyIncluded: "symbol body", confidence: "syntactic",
                        freshness: "fresh", estimatedTokens: 300),
        ]
        let working = WorkingState(sessionID: UUID(), workspaceID: "w", branch: "main",
                                   objective: "fix the refresh regression", plan: ["[ ] a"],
                                   touchedFiles: [], hypotheses: [], openQuestions: [],
                                   failingTests: [])
        let packet = ContextPacket(
            capsule: capsule, taskText: "t", items: items,
            symbols: [], relationships: [], sources: [],
            workingState: working, estimatedTokens: 3013)

        let (rows, details, total) = IntelligenceInspectorBuilder.requestBreakdown(
            packet: packet)

        XCTAssertEqual(total, 3013)
        XCTAssertEqual(rows[0].label, "Project Capsule")
        XCTAssertEqual(rows[0].tokens, capsule.estimatedTokens)
        XCTAssertTrue(rows.contains { $0.label == "Session lifecycle" })
        XCTAssertEqual(rows.first { $0.label == "Architecture" }?.tokens, 205)
        XCTAssertEqual(rows.first { $0.label == "Known pitfall" }?.tokens, 81)
        XCTAssertEqual(rows.first { $0.label == "2 symbols" }?.tokens, 200)
        XCTAssertEqual(rows.first { $0.label == "1 source snippet" }?.tokens, 300)

        XCTAssertEqual(details.count, 5)
        XCTAssertEqual(details[0].whyIncluded, "relevant to task")
        XCTAssertEqual(details[0].confidence, "verified")
        XCTAssertEqual(details[0].freshness, "fresh")
        XCTAssertEqual(details[0].tokens, 205)
    }

    func testBreakdownPluralizesPitfalls() {
        let capsule = ProjectCapsule(
            projectName: "Demo", languages: [], structure: [], hubSymbols: [],
            branch: nil, commit: nil, fileCount: 0, symbolCount: 0, edgeCount: 0,
            snapshotID: UUID(), generatedAt: Date(), staleKnowledgeCount: 0)
        let items = [
            ContextItem(section: .pitfall, id: "p1", text: "a", whyIncluded: "w",
                        confidence: "c", freshness: "f", estimatedTokens: 10),
            ContextItem(section: .pitfall, id: "p2", text: "b", whyIncluded: "w",
                        confidence: "c", freshness: "f", estimatedTokens: 10),
        ]
        let packet = ContextPacket(
            capsule: capsule, taskText: "t", items: items,
            symbols: [], relationships: [], sources: [],
            workingState: nil, estimatedTokens: 20)
        let (rows, _, _) = IntelligenceInspectorBuilder.requestBreakdown(packet: packet)
        XCTAssertTrue(rows.contains { $0.label == "Known pitfalls" })
    }
}
