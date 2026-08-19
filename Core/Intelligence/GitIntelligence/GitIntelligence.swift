import Foundation

/// Phase 16 — Git as an optional historical intelligence source. All reads
/// go through GitReader's sanitized /usr/bin/git invocation (fixed argument
/// lists, no shell, bounded by explicit limits). History is CONSULTED, not
/// injected: GitIntelligencePolicy decides when a task warrants it, and
/// nothing here feeds a prompt automatically.
struct CommitInfo: Sendable, Equatable {
    let hash: String
    let shortHash: String
    let author: String
    /// ISO-8601 author date as reported by git.
    let date: String
    let subject: String
}

struct BlameLine: Sendable, Equatable {
    let line: Int
    let commit: String
    let author: String
    let content: String
}

struct BranchContext: Sendable, Equatable {
    let branch: String?
    /// Files with uncommitted changes (porcelain status line count).
    let dirtyFileCount: Int
    /// Commits ahead of upstream, when an upstream exists.
    let ahead: Int?
    /// Commits behind upstream, when an upstream exists.
    let behind: Int?
}

final class GitIntelligence {

    let workspaceRoot: URL

    init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot
    }

    var isAvailable: Bool {
        GitReader.read(workspaceRoot: workspaceRoot) != nil
    }

    // MARK: History queries

    func recentCommits(limit: Int = 20) -> [CommitInfo] {
        log(["-\(limit)"])
    }

    /// Commits touching a workspace-relative file, newest first.
    func fileHistory(path: String, limit: Int = 20) -> [CommitInfo] {
        log(["-\(limit)", "--follow", "--", path])
    }

    /// Commits whose diff added or removed `term` (pickaxe) — the honest
    /// primitive for "when did X change" and regression search.
    func pickaxe(_ term: String, limit: Int = 20) -> [CommitInfo] {
        log(["-\(limit)", "-S\(term)"])
    }

    /// Regression search: commits introducing/removing a symbol-shaped term.
    func symbolHistory(_ symbolName: String, limit: Int = 20) -> [CommitInfo] {
        pickaxe(symbolName, limit: limit)
    }

    /// Number of commits touching `path` within the last `days` days — the
    /// change-frequency signal for hotspot detection.
    func changeFrequency(path: String, withinDays days: Int = 90) -> Int {
        guard let output = GitReader.git(workspaceRoot, [
            "log", "--since=\(days) days ago", "--format=%H", "--", path,
        ]) else { return 0 }
        return output.split(separator: "\n").count
    }

    // MARK: Blame

    /// Blame for a file or a 1-based inclusive line range. Renames followed
    /// (-C -M) so moved code keeps its provenance.
    func blame(path: String, lines range: ClosedRange<Int>? = nil) -> [BlameLine] {
        var arguments = ["blame", "--line-porcelain", "-C", "-M"]
        if let range { arguments += ["-L", "\(range.lowerBound),\(range.upperBound)"] }
        arguments += ["--", path]
        guard let output = GitReader.git(workspaceRoot, arguments) else { return [] }
        return Self.parseBlame(output)
    }

    static func parseBlame(_ output: String) -> [BlameLine] {
        var results: [BlameLine] = []
        var commit = ""
        var author = ""
        var finalLine = 0
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let match = line.range(
                of: #"^[0-9a-f]{40} \d+ (\d+)"#, options: .regularExpression) {
                let header = String(line[match])
                let parts = header.split(separator: " ")
                commit = String(parts[0])
                finalLine = Int(parts[2]) ?? 0
                author = ""
            } else if line.hasPrefix("author ") {
                author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("\t") {
                results.append(BlameLine(
                    line: finalLine, commit: commit, author: author,
                    content: String(line.dropFirst())))
            }
        }
        return results
    }

    // MARK: Branch context

    func branchContext() -> BranchContext {
        let state = GitReader.read(workspaceRoot: workspaceRoot)
        let dirty = GitReader.git(workspaceRoot, ["status", "--porcelain"])?
            .split(separator: "\n").count ?? 0
        var ahead: Int?
        var behind: Int?
        if let counts = GitReader.git(
            workspaceRoot, ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]) {
            let parts = counts.split(whereSeparator: \.isWhitespace)
            if parts.count == 2 {
                ahead = Int(parts[0])
                behind = Int(parts[1])
            }
        }
        return BranchContext(
            branch: state?.branch, dirtyFileCount: dirty, ahead: ahead, behind: behind)
    }

    // MARK: Internals

    private func log(_ extra: [String]) -> [CommitInfo] {
        let format = "--format=%H%x1f%h%x1f%an%x1f%aI%x1f%s"
        guard let output = GitReader.git(workspaceRoot, ["log", format] + extra)
        else { return [] }
        return output.split(separator: "\n").compactMap { raw in
            let fields = raw.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 5 else { return nil }
            return CommitInfo(
                hash: String(fields[0]), shortHash: String(fields[1]),
                author: String(fields[2]), date: String(fields[3]),
                subject: String(fields[4]))
        }
    }
}

/// Deterministic gate (spec Phase 16): Git history enters a task ONLY when
/// the task's wording warrants it. Keyword-driven, transparent, testable —
/// no LLM judgment call, no automatic injection.
enum GitIntelligencePolicy {

    private static let warrants: [String] = [
        "regression", "broke", "broken", "history", "blame",
        "who changed", "who wrote", "when did", "last working",
        "used to work", "introduced", "revert", "reverted",
        "recently changed", "what changed",
    ]

    static func shouldConsult(taskDescription: String) -> Bool {
        let lower = taskDescription.lowercased()
        return warrants.contains { lower.contains($0) }
    }
}
