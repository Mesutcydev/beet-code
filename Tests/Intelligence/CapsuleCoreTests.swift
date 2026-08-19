import Foundation
import XCTest
@testable import BeetCode

/// Phase 7 — Project Capsule. Capsules are generated from real indexed
/// fixtures; budget behavior and regeneration are verified, not assumed.
final class CapsuleCoreTests: XCTestCase {

    private var retainedStores: [TempWorkspace] = []

    private func indexedWorkspace() throws -> (TempWorkspace, IndexEngine, WorkspaceSnapshot) {
        let ws = TempWorkspace()
        ws.write("""
        import Foundation
        struct Networking { func send() {} }
        """, to: "Core/Networking.swift")
        ws.write("""
        import SwiftUI
        struct HomeView: View { var body: some View { Text("hi") } }
        """, to: "App/HomeView.swift")
        ws.write("""
        import Foundation
        struct Caller { func go() { Networking().send() } }
        """, to: "App/Caller.swift")

        let storeDir = TempWorkspace()
        retainedStores.append(storeDir)
        IntelligenceStoreLayout.overrideRoot = storeDir.url
        let snapshotStore = WorkspaceSnapshotStore()
        snapshotStore.overrideDirectory = storeDir.url.appendingPathComponent("snapshots")
        let identity = WorkspaceIdentity.resolve(root: ws.url)
        let graph = try SymbolGraph(store: SQLiteStore(url: storeDir.url.appendingPathComponent("g.sqlite")))
        let journal = try InvalidationJournal(store: SQLiteStore(url: storeDir.url.appendingPathComponent("m.sqlite")))
        let engine = IndexEngine(identity: identity, graph: graph, journal: journal,
                                 snapshotStore: snapshotStore)
        return (ws, engine, WorkspaceScanner.capture(identity: identity))
    }

    func testCapsuleReflectsRealIndex() async throws {
        let (ws, engine, _) = try indexedWorkspace()
        try await engine.fullIndex()
        let snapshot = WorkspaceScanner.capture(identity: WorkspaceIdentity.resolve(root: ws.url))
        let capsule = try await CapsuleGenerator.generate(
            identity: WorkspaceIdentity.resolve(root: ws.url),
            snapshot: snapshot, graph: engine.graphHandle)

        XCTAssertEqual(capsule.fileCount, 3)
        XCTAssertEqual(capsule.symbolCount, 3)
        XCTAssertEqual(capsule.languages.first?.language, "swift")
        XCTAssertEqual(capsule.languages.first?.files, 3)
        XCTAssertFalse(capsule.structure.isEmpty)
    }

    func testCapsuleStaysWithinTokenBudget() async throws {
        let (ws, engine, _) = try indexedWorkspace()
        // Many directories to force truncation pressure.
        for i in 0..<30 {
            ws.write("struct S\(i) {}", to: "Dir\(i)/File\(i).swift")
        }
        try await engine.fullIndex()
        let snapshot = WorkspaceScanner.capture(identity: WorkspaceIdentity.resolve(root: ws.url))
        let capsule = try await CapsuleGenerator.generate(
            identity: WorkspaceIdentity.resolve(root: ws.url),
            snapshot: snapshot, graph: engine.graphHandle)

        let rendered = capsule.rendered(tokenBudget: 800)
        XCTAssertLessThanOrEqual(rendered.count / 4, 800)
        // Header survives any budget pressure.
        XCTAssertTrue(rendered.hasPrefix("PROJECT CAPSULE"))
    }

    func testCapsuleRegeneratesWhenStructureChanges() async throws {
        let (ws, engine, _) = try indexedWorkspace()
        try await engine.fullIndex()
        let identity = WorkspaceIdentity.resolve(root: ws.url)
        let before = try await CapsuleGenerator.generate(
            identity: identity,
            snapshot: WorkspaceScanner.capture(identity: identity),
            graph: engine.graphHandle)

        ws.write("struct Extra { func added() {} }", to: "Core/Extra.swift")
        try await engine.incrementalUpdate()
        let after = try await CapsuleGenerator.generate(
            identity: identity,
            snapshot: WorkspaceScanner.capture(identity: identity),
            graph: engine.graphHandle)

        XCTAssertNotEqual(before.symbolCount, after.symbolCount)
        XCTAssertEqual(after.fileCount, before.fileCount + 1)
        XCTAssertTrue(after.rendered().contains("Extra") || after.symbolCount > before.symbolCount)
    }

    func testCapsuleCodableRoundTrip() async throws {
        let (ws, engine, _) = try indexedWorkspace()
        try await engine.fullIndex()
        let identity = WorkspaceIdentity.resolve(root: ws.url)
        let capsule = try await CapsuleGenerator.generate(
            identity: identity,
            snapshot: WorkspaceScanner.capture(identity: identity),
            graph: engine.graphHandle)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(capsule)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectCapsule.self, from: data)
        XCTAssertEqual(decoded.projectName, capsule.projectName)
        XCTAssertEqual(decoded.symbolCount, capsule.symbolCount)
        XCTAssertEqual(decoded.languages.map(\.language), capsule.languages.map(\.language))
    }
}
