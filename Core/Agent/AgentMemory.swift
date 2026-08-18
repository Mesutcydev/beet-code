import Foundation

/// Memory modes: how much long-term memory the agent uses across sessions.
enum MemoryMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case summaries
    case facts
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .summaries: "Session summaries"
        case .facts: "Facts"
        case .full: "Summaries + facts"
        }
    }

    var includeFacts: Bool { self == .facts || self == .full }
    var includeSummaries: Bool { self == .summaries || self == .full }
}

/// One durable fact the agent learned about the user's project.
struct MemoryFact: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var createdAt: Date
    var lastUsedAt: Date
    var source: String  // e.g. "turn 3", "completion", "memory_add"
}

/// A rolling summary of an earlier session in this workspace.
struct MemorySummary: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var createdAt: Date
    var sessionTitle: String
}

/// Mem0/Letta-inspired long-term memory for a workspace: durable facts plus
/// session summaries, persisted per workspace under Application Support.
/// The agent can also maintain facts explicitly through memory_add/
/// memory_delete tools.
final class AgentMemory: @unchecked Sendable {

    let workspaceKey: String
    private let lock = NSLock()
    private var facts: [MemoryFact] = []
    private var summaries: [MemorySummary] = []

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeetCode/Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(workspaceKey).json")
    }

    init(workspacePath: String) {
        self.workspaceKey = AgentMemory.key(for: workspacePath)
        load()
    }

    static func key(for workspacePath: String) -> String {
        // Stable, filesystem-safe key derived from the workspace path.
        let digest = workspacePath.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return String(format: "ws-%08x", digest)
    }

    // MARK: Facts

    var allFacts: [MemoryFact] {
        withLock { facts.sorted { $0.lastUsedAt > $1.lastUsedAt } }
    }

    @discardableResult
    func addFact(_ text: String, source: String = "agent") -> MemoryFact? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return nil }
        let fact = MemoryFact(
            id: UUID(),
            text: trimmed,
            createdAt: Date(),
            lastUsedAt: Date(),
            source: source)
        withLock {
            // Deduplicate near-identical facts (Mem0-style upsert).
            facts.removeAll { existing in
                existing.text.lowercased() == trimmed.lowercased()
            }
            facts.append(fact)
            // Bounded retention: keep the 200 most recent facts.
            if facts.count > 200 {
                facts.sort { $0.createdAt > $1.createdAt }
                facts.removeLast(facts.count - 200)
            }
        }
        persist()
        return fact
    }

    func deleteFact(id: UUID) {
        withLock { facts.removeAll { $0.id == id } }
        persist()
    }

    func deleteFact(text: String) {
        withLock { facts.removeAll { $0.text.lowercased() == text.lowercased() } }
        persist()
    }

    /// Read-only snapshot of stored facts (for `/memory`).
    func listFacts() -> [MemoryFact] {
        withLock { facts }
    }

    /// Marks facts as used (recency ranking for prompt injection).
    func touchFact(id: UUID) {
        withLock {
            guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
            facts[index].lastUsedAt = Date()
        }
        persist()
    }

    // MARK: Summaries

    var allSummaries: [MemorySummary] {
        withLock { summaries.sorted { $0.createdAt > $1.createdAt } }
    }

    @discardableResult
    func addSummary(_ text: String, sessionTitle: String) -> MemorySummary? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 16 else { return nil }
        let summary = MemorySummary(
            id: UUID(),
            text: trimmed,
            createdAt: Date(),
            sessionTitle: sessionTitle)
        withLock {
            summaries.append(summary)
            if summaries.count > 50 {
                summaries.sort { $0.createdAt > $1.createdAt }
                summaries.removeLast(summaries.count - 50)
            }
        }
        persist()
        return summary
    }

    // MARK: Memory contexting (v0.3)

    /// Builds the bounded memory section for the system prompt: the most
    /// relevant facts and the most recent summaries, keyword-scored so
    /// facts about the current task surface first.
    func contextSection(mode: MemoryMode, taskHint: String, maxFacts: Int = 12, maxSummaries: Int = 3) -> String? {
        var sections: [String] = []
        if mode.includeFacts {
            let scored = allFacts.map { fact -> (MemoryFact, Int) in
                let keywords = taskHint.lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .filter { $0.count > 3 }
                let score = keywords.reduce(0) { partial, keyword in
                    partial + (fact.text.lowercased().contains(keyword) ? 2 : 0)
                }
                return (fact, score)
            }
            let picked = scored.sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0.lastUsedAt > rhs.0.lastUsedAt
            }.prefix(maxFacts).map(\.0)
            if !picked.isEmpty {
                sections.append(
                    "## What I remember about this project\n"
                    + picked.map { "- \($0.text)" }.joined(separator: "\n"))
            }
        }
        if mode.includeSummaries {
            let recent = Array(allSummaries.prefix(maxSummaries))
            if !recent.isEmpty {
                sections.append(
                    "## Earlier sessions\n"
                    + recent.map { "- (\($0.sessionTitle)) \($0.text)" }.joined(separator: "\n"))
            }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var facts: [MemoryFact]
        var summaries: [MemorySummary]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        withLock {
            facts = snapshot.facts
            summaries = snapshot.summaries
        }
    }

    private func persist() {
        let snapshot = withLock { Snapshot(facts: facts, summaries: summaries) }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}