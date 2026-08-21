import Foundation

/// A temporary linked Git worktree seeded from the parent's exact working
/// tree, including untracked files. Implementation subagents can work here
/// without racing the visible workspace; their final tree is merged back as
/// one checked patch.
struct AgentWorktree: Sendable {
    enum WorktreeError: Error, LocalizedError {
        case noRepository
        case workspaceIsNotRepositoryRoot
        case gitFailed(String)
        case mergeConflict(String)

        var errorDescription: String? {
            switch self {
            case .noRepository:
                "The workspace is not a Git repository."
            case .workspaceIsNotRepositoryRoot:
                "Isolated subagents currently require the repository root to be open."
            case .gitFailed(let output):
                "Git worktree setup failed: \(output)"
            case .mergeConflict(let output):
                "The isolated result no longer applies cleanly: \(output)"
            }
        }
    }

    let id: String
    let parentWorkspace: URL
    let workspaceURL: URL
    let baseTree: String
    let baseCheckpoint: SessionCheckpoint

    static func prepare(parentWorkspace: URL) throws -> AgentWorktree {
        let canonicalParent = WorkspaceIdentity.canonicalize(parentWorkspace)
        let topLevel = try git(
            ["rev-parse", "--show-toplevel"],
            in: canonicalParent)
        guard topLevel.exitCode == 0 else { throw WorktreeError.noRepository }
        let repositoryRoot = WorkspaceIdentity.canonicalize(URL(
            fileURLWithPath: topLevel.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard repositoryRoot.path == canonicalParent.path else {
            throw WorktreeError.workspaceIsNotRepositoryRoot
        }

        let checkpoint = try GitCheckpointer(workspace: Workspace(root: canonicalParent))
            .snapshot(summary: "Before isolated implementation")
        let baseTree = checkpoint.treeSHA
        let commit = try temporaryCommit(tree: baseTree, in: canonicalParent)
        let id = UUID().uuidString.lowercased()
        let parentKey = String(ContentDigest.sha256Hex(canonicalParent.path).prefix(12))
        let worktreeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-agent-worktrees", isDirectory: true)
            .appendingPathComponent(parentKey, isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let destination = worktreeRoot.appendingPathComponent(id, isDirectory: true)

        let add = try git(
            ["worktree", "add", "--detach", destination.path, commit],
            in: canonicalParent)
        guard add.exitCode == 0 else {
            throw WorktreeError.gitFailed(add.output)
        }
        return AgentWorktree(
            id: id,
            parentWorkspace: canonicalParent,
            workspaceURL: destination,
            baseTree: baseTree,
            baseCheckpoint: checkpoint)
    }

    /// Applies the complete child tree to the visible workspace. A dry run
    /// happens first, so a conflict cannot leave a half-applied patch.
    func merge() throws -> MergeSummary {
        let finalCheckpoint = try GitCheckpointer(workspace: Workspace(root: workspaceURL))
            .snapshot(summary: "Isolated implementation result")
        let finalTree = finalCheckpoint.treeSHA
        guard finalTree != baseTree else {
            return MergeSummary(files: [], insertions: 0, deletions: 0)
        }

        let patch = try Self.git(
            ["diff", "--binary", "--full-index", baseTree, finalTree],
            in: workspaceURL)
        guard patch.exitCode == 0 else { throw WorktreeError.gitFailed(patch.output) }

        let patchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-worktree-\(id).patch")
        defer { try? FileManager.default.removeItem(at: patchURL) }
        try patch.output.write(to: patchURL, atomically: true, encoding: .utf8)

        let check = try Self.git(
            ["apply", "--check", "--binary", patchURL.path],
            in: parentWorkspace)
        guard check.exitCode == 0 else {
            throw WorktreeError.mergeConflict(check.output)
        }
        let apply = try Self.git(
            ["apply", "--binary", patchURL.path],
            in: parentWorkspace)
        guard apply.exitCode == 0 else {
            throw WorktreeError.mergeConflict(apply.output)
        }

        let names = try Self.git(
            ["diff", "--name-only", baseTree, finalTree],
            in: workspaceURL)
            .output
            .split(separator: "\n")
            .map(String.init)
        let stats = try Self.git(
            ["diff", "--numstat", baseTree, finalTree],
            in: workspaceURL)
        var insertions = 0
        var deletions = 0
        for line in stats.output.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            if fields.count >= 2 {
                insertions += Int(fields[0]) ?? 0
                deletions += Int(fields[1]) ?? 0
            }
        }
        return MergeSummary(files: names, insertions: insertions, deletions: deletions)
    }

    func remove() throws {
        let result = try Self.git(
            ["worktree", "remove", "--force", workspaceURL.path],
            in: parentWorkspace)
        guard result.exitCode == 0 else {
            throw WorktreeError.gitFailed(result.output)
        }
    }

    struct MergeSummary: Sendable, Equatable {
        let files: [String]
        let insertions: Int
        let deletions: Int

        var description: String {
            if files.isEmpty { return "No file changes." }
            return "Merged \(files.count) file(s), +\(insertions) −\(deletions):\n"
                + files.map { "• \($0)" }.joined(separator: "\n")
        }
    }
}

private extension AgentWorktree {
    static func temporaryCommit(tree: String, in workspace: URL) throws -> String {
        var environment = ShellRunner.sanitizedEnvironment()
        environment["GIT_AUTHOR_NAME"] = "Beet Code"
        environment["GIT_AUTHOR_EMAIL"] = "agent@beetcode.local"
        environment["GIT_COMMITTER_NAME"] = "Beet Code"
        environment["GIT_COMMITTER_EMAIL"] = "agent@beetcode.local"

        var arguments = ["commit-tree", tree, "-m", "Beet Code isolated agent base"]
        let head = try git(["rev-parse", "--verify", "HEAD"], in: workspace)
        if head.exitCode == 0 {
            let parent = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !parent.isEmpty {
                arguments.insert(contentsOf: ["-p", parent], at: 2)
            }
        }
        let result = try git(arguments, in: workspace, environment: environment)
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.output) }
        let commit = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty else { throw WorktreeError.gitFailed("commit-tree returned no commit") }
        return commit
    }

    static func git(
        _ arguments: [String],
        in workspace: URL,
        environment: [String: String] = ShellRunner.sanitizedEnvironment()
    ) throws -> CommandResult {
        try ShellRunner.runProcess(
            executable: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: workspace,
            environment: environment,
            timeout: 60)
    }
}
