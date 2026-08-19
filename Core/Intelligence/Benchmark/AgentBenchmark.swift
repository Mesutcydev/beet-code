import Foundation

/// Phase 24 — benchmark harness comparing agent exploration with and
/// without Workspace Intelligence.
///
/// HONESTY NOTE: this is a *simulated-agent* benchmark. It deterministically
/// measures what the spec's success criterion is about — redundant
/// repository exploration and unverifiable assumptions — using two explicit
/// exploration policies, not live LLM sessions:
///
///   A. "normal agent": grep-style exploration. Opens files in path order,
///      skimming for task-relevant tokens, until it has located the target
///      symbol's definition and one usage. Has no way to check structural
///      claims, so a plausible-but-false claim stands as an assumption.
///   B. "intelligence agent": compiles one ContextPacket, opens only files
///      the packet actually anchors, and runs claim verification.
///
/// A live-model A/B is a separate, non-deterministic exercise; this harness
/// exists so the exploration-cost delta is reproducible in CI.
struct BenchmarkTask: Sendable {
    let name: String
    /// Natural-language task text (drives token extraction).
    let text: String
    /// Symbol the task is about.
    let targetSymbol: String
    /// A plausible-but-false structural claim about the target area.
    let falseClaim: (caller: String, callee: String)
}

struct AgentRunMetrics: Sendable, Equatable {
    let filesOpened: Int
    let inputTokens: Int
    let toolCalls: Int
    /// False structural claims the agent had no way to catch.
    let uncaughtFalseAssumptions: Int
}

struct BenchmarkResult: Sendable {
    let task: String
    let withoutIntelligence: AgentRunMetrics
    let withIntelligence: AgentRunMetrics
}

enum AgentBenchmark {

    /// Agent A: grep-style exploration over the real file tree.
    static func runWithoutIntelligence(
        task: BenchmarkTask, workspaceRoot: URL, relativeFiles: [String]
    ) -> AgentRunMetrics {
        var filesOpened = 0
        var tokens = 0
        var toolCalls = 0
        var foundDefinition = false
        var foundUsage = false

        for path in relativeFiles.sorted() {
            guard !foundDefinition || !foundUsage else { break }
            guard let url = PathSafety.resolve(root: workspaceRoot, relative: path),
                  let content = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            filesOpened += 1
            toolCalls += 1
            tokens += content.count / 4
            if content.contains("func \(task.targetSymbol)") {
                foundDefinition = true
            } else if content.contains("\(task.targetSymbol)(") {
                foundUsage = true
            }
        }
        // No structural oracle: the false claim survives.
        return AgentRunMetrics(
            filesOpened: filesOpened, inputTokens: tokens, toolCalls: toolCalls,
            uncaughtFalseAssumptions: 1)
    }

    /// Agent B: one compiled packet + claim verification.
    static func runWithIntelligence(
        task: BenchmarkTask, intel: WorkspaceIntelligence
    ) throws -> AgentRunMetrics {
        var toolCalls = 0

        let packet = try intel.context(for: task.text)
        toolCalls += 1
        let anchoredFiles = Set(packet.symbols.map(\.path)
            + packet.sources.map(\.path)).filter { !$0.isEmpty }

        // Claim verification catches the false structural claim.
        toolCalls += 1
        let verdict = try intel.verifier().callExists(
            caller: task.falseClaim.caller, callee: task.falseClaim.callee)
        let uncaught: Int
        switch verdict {
        case .verified: uncaught = 1      // claim was actually true — bad task
        case .false_: uncaught = 0        // caught, with evidence
        case .unverified: uncaught = 1    // no signal either way
        }

        return AgentRunMetrics(
            filesOpened: anchoredFiles.count,
            inputTokens: packet.estimatedTokens,
            toolCalls: toolCalls,
            uncaughtFalseAssumptions: uncaught)
    }

    static func render(_ results: [BenchmarkResult]) -> String {
        var lines = [
            "task | files A→B | tokens A→B | tool calls A→B | false assumptions A→B",
            "---|---|---|---|---",
        ]
        for result in results {
            let a = result.withoutIntelligence
            let b = result.withIntelligence
            lines.append(
                "\(result.task) | \(a.filesOpened) → \(b.filesOpened) | "
                + "\(a.inputTokens) → \(b.inputTokens) | "
                + "\(a.toolCalls) → \(b.toolCalls) | "
                + "\(a.uncaughtFalseAssumptions) → \(b.uncaughtFalseAssumptions)")
        }
        return lines.joined(separator: "\n")
    }
}
