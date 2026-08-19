import Foundation
import XCTest
@testable import BeetCode

/// Phase 8+9 — Knowledge store and the proposal pipeline. Covers every
/// spec-required case: duplicate, conflicting, stale evidence, deleted
/// evidence, secret-containing, unsupported, verified.
final class KnowledgeCoreTests: XCTestCase {

    private func makeStack(
        hashes: [String: String] = [:],
        graph: SymbolGraph? = nil
    ) throws -> (KnowledgeStore, KnowledgePipeline, SymbolGraph) {
        let store = try KnowledgeStore(store: SQLiteStore(
            url: URL(fileURLWithPath: ":memory:"), inMemory: true))
        let graph = try graph ?? SymbolGraph(store: SQLiteStore(
            url: URL(fileURLWithPath: ":memory:"), inMemory: true))
        let pipeline = KnowledgePipeline(
            store: store, graph: graph,
            hashProvider: { hashes[$0] },
            gitCommitProvider: { "abc1234" })
        return (store, pipeline, graph)
    }

    private func proposal(
        statement: String,
        kind: KnowledgeKind = .capability,
        scope: String = "InferenceServer",
        paths: [String] = ["Sources/Inference.swift"],
        symbols: [String] = [],
        origin: String = "agent"
    ) -> KnowledgeProposal {
        KnowledgeProposal(kind: kind, scope: scope, statement: statement,
                          evidencePaths: paths, evidenceSymbols: symbols,
                          branchScope: nil, origin: origin)
    }

    private let hashes = ["Sources/Inference.swift": "hash-v1"]

    // MARK: Store basics

    func testInsertAndReadBack() throws {
        let (store, _, _) = try makeStack()
        let record = KnowledgeRecord(
            id: "kn_test1", kind: .capability, scope: "InferenceServer",
            statement: "Inference responses support SSE streaming.",
            confidence: .verified, freshness: .fresh,
            evidence: [Evidence(path: "Sources/Inference.swift", symbolID: "sym_x",
                                startLine: 10, endLine: 40, contentHash: "hash-v1",
                                gitCommit: "abc1234", capturedAt: Date())],
            branchScope: nil, createdAt: Date(), updatedAt: Date())
        try store.insert(record)
        let loaded = try store.record(id: "kn_test1")
        XCTAssertEqual(loaded?.statement, record.statement)
        XCTAssertEqual(loaded?.confidence, .verified)
        XCTAssertEqual(loaded?.evidence.count, 1)
        XCTAssertEqual(loaded?.evidence.first?.contentHash, "hash-v1")
    }

    // MARK: Freshness (spec §7)

    func testStaleOnHashChangeInvalidOnDelete() throws {
        let (store, _, _) = try makeStack()
        let record = KnowledgeRecord(
            id: "kn_stale", kind: .capability, scope: "S",
            statement: "Something true about the file.",
            confidence: .verified, freshness: .fresh,
            evidence: [Evidence(path: "a.swift", symbolID: nil, startLine: nil,
                                endLine: nil, contentHash: "v1",
                                gitCommit: nil, capturedAt: Date())],
            branchScope: nil, createdAt: Date(), updatedAt: Date())
        try store.insert(record)

        // File changed → stale. Deterministic; no LLM involved.
        var changed = try store.reevaluateFreshness(currentHashes: ["a.swift": "v2"])
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try store.record(id: "kn_stale")?.freshness, .stale)

        // File deleted → invalid.
        let record2 = KnowledgeRecord(
            id: "kn_gone", kind: .capability, scope: "S",
            statement: "Something about a now-deleted file.",
            confidence: .verified, freshness: .fresh,
            evidence: [Evidence(path: "gone.swift", symbolID: nil, startLine: nil,
                                endLine: nil, contentHash: "v1",
                                gitCommit: nil, capturedAt: Date())],
            branchScope: nil, createdAt: Date(), updatedAt: Date())
        try store.insert(record2)
        changed = try store.reevaluateFreshness(currentHashes: ["gone.swift": nil])
        XCTAssertEqual(try store.record(id: "kn_gone")?.freshness, .invalid)
    }

    // MARK: Pipeline

    func testVerifiedClaimCommits() throws {
        let (_, pipeline, graph) = try makeStack(hashes: hashes)
        // Index the cited symbol so graph verification can pass.
        let file = SourceFile(
            path: "Sources/Inference.swift",
            content: "struct InferenceServer {\n func stream() {}\n}",
            contentHash: "hash-v1")
        try graph.upsertFile(ParserRegistry.parse(file: file)!)

        let result = try pipeline.propose(proposal(
            statement: "Inference responses support SSE streaming.",
            symbols: ["stream"]))
        guard case .committed(let id, let confidence) = result else {
            return XCTFail("expected commit, got \(result)")
        }
        XCTAssertEqual(confidence, .verified)
        XCTAssertEqual(id.hasPrefix("kn_"), true)
    }

    func testDuplicateRejected() throws {
        let (_, pipeline, _) = try makeStack(hashes: hashes)
        let first = try pipeline.propose(proposal(
            statement: "Inference responses support SSE streaming."))
        guard case .committed = first else { return XCTFail() }
        let second = try pipeline.propose(proposal(
            statement: "Inference responses support SSE streaming."))
        XCTAssertEqual(second, .duplicate(existingID: {
            if case .committed(let id, _) = first { return id }
            return ""
        }()))
    }

    func testConflictingClaimHeldNotCommitted() throws {
        let (_, pipeline, _) = try makeStack(hashes: hashes)
        _ = try pipeline.propose(proposal(
            statement: "The inference server supports SSE streaming responses."))
        let conflict = try pipeline.propose(proposal(
            statement: "The inference server does not support SSE streaming responses."))
        guard case .conflict = conflict else {
            return XCTFail("expected conflict, got \(conflict)")
        }
    }

    func testSecretProposalRejected() throws {
        let (_, pipeline, _) = try makeStack(hashes: hashes)
        let result = try pipeline.propose(proposal(
            statement: "The staging API key is sk-abcdefghij0123456789abcd for the proxy."))
        guard case .rejected(let reason) = result else {
            return XCTFail("expected rejection, got \(result)")
        }
        XCTAssertTrue(reason.contains("secret"))
    }

    func testUnsupportedClaimRejected() throws {
        let (_, pipeline, _) = try makeStack(hashes: hashes)
        // No evidence paths, no symbols, agent origin → cannot persist.
        let result = try pipeline.propose(proposal(
            statement: "The server probably caches aggressively somewhere.",
            paths: []))
        guard case .rejected = result else {
            return XCTFail("expected rejection, got \(result)")
        }
    }

    func testDeletedEvidencePathRejected() throws {
        let (_, pipeline, _) = try makeStack(hashes: [:]) // file not indexed
        let result = try pipeline.propose(proposal(
            statement: "Inference responses support SSE streaming."))
        guard case .rejected(let reason) = result else {
            return XCTFail("expected rejection, got \(result)")
        }
        XCTAssertTrue(reason.contains("not in the index"))
    }

    func testUnknownSymbolRejected() throws {
        let (_, pipeline, _) = try makeStack(hashes: hashes)
        let result = try pipeline.propose(proposal(
            statement: "Streaming uses the mythical FluxCapacitor type.",
            symbols: ["FluxCapacitor"]))
        guard case .rejected(let reason) = result else {
            return XCTFail("expected rejection, got \(result)")
        }
        XCTAssertTrue(reason.contains("FluxCapacitor"))
    }

    func testUserOriginNeedsNoGraphVerification() throws {
        let (_, pipeline, _) = try makeStack(hashes: hashes)
        let result = try pipeline.propose(proposal(
            statement: "Deploys happen every Friday at 16:00 UTC.",
            kind: .convention, origin: "user"))
        guard case .committed(_, let confidence) = result else {
            return XCTFail("expected commit, got \(result)")
        }
        XCTAssertEqual(confidence, .verified) // user + file evidence
    }
}
