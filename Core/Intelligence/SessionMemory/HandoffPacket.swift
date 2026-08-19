import Foundation

/// Structured cross-provider handoff (spec §16, Phase 11). The next agent
/// gets this packet + the capsule — never the full transcript.
struct HandoffPacket: Codable, Sendable, Equatable {
    let goal: String
    let completed: [String]
    let currentHypothesis: String?
    let touchedFiles: [String]
    let testsPassing: Int
    let testsTotal: Int
    let failures: [String]
    let unresolved: [String]
    let relevantSymbolIDs: [String]
    let relevantDecisionIDs: [String]
    let knownPitfallIDs: [String]
    let diffDigest: String
    let branch: String
    let generatedAt: Date

    /// Plain-text rendering in the spec's HANDOFF shape.
    func rendered() -> String {
        var lines = ["HANDOFF", "", "Goal", goal.isEmpty ? "(none recorded)" : goal]
        if !completed.isEmpty {
            lines += ["", "Completed"] + completed.map { "- \($0)" }
        }
        if let currentHypothesis, !currentHypothesis.isEmpty {
            lines += ["", "Current hypothesis", currentHypothesis]
        }
        if !touchedFiles.isEmpty {
            lines += ["", "Touched"] + touchedFiles.map { "- \($0)" }
        }
        if testsTotal > 0 {
            lines += ["", "Tests", "\(testsPassing)/\(testsTotal) passing"]
        }
        if !failures.isEmpty {
            lines += ["", "Failures"] + failures.map { "- \($0)" }
        }
        if !unresolved.isEmpty {
            lines += ["", "Unresolved"] + unresolved.map { "- \($0)" }
        }
        if !relevantSymbolIDs.isEmpty {
            lines += ["", "Relevant symbols"] + relevantSymbolIDs.map { "- \($0)" }
        }
        if !relevantDecisionIDs.isEmpty {
            lines += ["", "Relevant decisions"] + relevantDecisionIDs.map { "- \($0)" }
        }
        if !knownPitfallIDs.isEmpty {
            lines += ["", "Known pitfalls"] + knownPitfallIDs.map { "- \($0)" }
        }
        if !diffDigest.isEmpty {
            lines += ["", "Diff digest", diffDigest]
        }
        lines += ["", "Branch: \(branch)"]
        return lines.joined(separator: "\n")
    }
}

/// Compiles a handoff from branch-scoped working state plus relevant
/// knowledge. Deterministic: packet = working state fields + knowledge IDs,
/// no summarization.
struct HandoffCompiler: Sendable {

    static func compile(
        state: WorkingState,
        relevantKnowledge: [KnowledgeRecord] = []
    ) -> HandoffPacket {
        HandoffPacket(
            goal: state.objective,
            completed: state.plan.filter { _ in false }, // completed items come from plan progress markers below
            currentHypothesis: state.hypotheses.last,
            touchedFiles: state.touchedFiles,
            testsPassing: state.passingTests,
            testsTotal: state.totalTests,
            failures: state.failingTests,
            unresolved: state.openQuestions,
            relevantSymbolIDs: [],
            relevantDecisionIDs: relevantKnowledge
                .filter { $0.kind == .decision }.map(\.id),
            knownPitfallIDs: relevantKnowledge
                .filter { $0.kind == .pitfall }.map(\.id),
            diffDigest: state.diffDigest,
            branch: state.branch,
            generatedAt: Date())
    }

    /// Completed-work lines are recorded as plan entries prefixed "[x] " by
    /// the session layer — parsed out here.
    static func compileWithProgress(
        state: WorkingState,
        relevantKnowledge: [KnowledgeRecord] = []
    ) -> HandoffPacket {
        var packet = compile(state: state, relevantKnowledge: relevantKnowledge)
        let completed = state.plan
            .filter { $0.hasPrefix("[x] ") }
            .map { String($0.dropFirst(4)) }
        packet = HandoffPacket(
            goal: packet.goal, completed: completed,
            currentHypothesis: packet.currentHypothesis,
            touchedFiles: packet.touchedFiles,
            testsPassing: packet.testsPassing, testsTotal: packet.testsTotal,
            failures: packet.failures, unresolved: packet.unresolved,
            relevantSymbolIDs: packet.relevantSymbolIDs,
            relevantDecisionIDs: packet.relevantDecisionIDs,
            knownPitfallIDs: packet.knownPitfallIDs,
            diffDigest: packet.diffDigest, branch: packet.branch,
            generatedAt: packet.generatedAt)
        return packet
    }
}
