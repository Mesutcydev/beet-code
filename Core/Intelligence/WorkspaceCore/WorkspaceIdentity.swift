import Foundation

/// Git state of a workspace at resolution time. Read-only facts gathered by
/// shelling out to the system git — the same trust level as the workspace
/// itself (deterministic, never model-supplied).
struct GitState: Codable, Sendable, Equatable {
    /// Canonical path of the repository top level (`git rev-parse --show-toplevel`).
    let repositoryRoot: String
    /// Current branch name, or nil when HEAD is detached.
    let branch: String?
    /// Full HEAD commit hash, or nil on a repository with no commits.
    let commit: String?
    /// True when the workspace is a linked worktree (`.git` is a file, not a directory).
    let isWorktree: Bool
    /// `remote.origin.url`, normalized (trailing `.git`/slash stripped), if configured.
    let remoteURL: String?
    /// Hash of the root (first) commit — stable across renames/moves of the
    /// working tree and identical for clones of the same project.
    let rootCommit: String?
}

/// Canonical, move-safe identity of a workspace. The workspace ID is derived
/// from Git facts when available (remote URL or root commit), so renaming or
/// moving the working tree does not orphan its intelligence store. Workspaces
/// outside Git fall back to a canonical-path identity — documented behavior,
/// not hidden state.
struct WorkspaceIdentity: Codable, Sendable, Equatable {
    /// Stable store key, e.g. `wks_9f2ac41b0e77d2c1`.
    let workspaceID: String
    /// Fully symlink-resolved absolute path of the workspace root.
    let canonicalPath: String
    /// Last path component for display only — never used as identity.
    let displayName: String
    /// Git facts at resolution time; nil when the workspace is not a repository.
    let git: GitState?

    /// Resolves the identity for a workspace root. Cheap enough to run on
    /// every open; deterministic for a given (path, git) state.
    static func resolve(root: URL) -> WorkspaceIdentity {
        let canonical = canonicalize(root)
        let git = GitReader.read(workspaceRoot: canonical)

        let idSource: String
        if let git {
            // Remote URL identifies the project across machines and moves;
            // root commit identifies it when no remote exists. Both survive
            // working-tree renames — the repository path itself is
            // deliberately NOT part of the ID so moves stay identity-stable.
            let base = git.remoteURL ?? git.rootCommit ?? git.repositoryRoot
            idSource = "git:\(base)"
        } else {
            idSource = "path:\(canonical.path)"
        }
        let digest = ContentDigest.sha256Hex(idSource)
        return WorkspaceIdentity(
            workspaceID: "wks_" + digest.prefix(16),
            canonicalPath: canonical.path,
            displayName: canonical.lastPathComponent,
            git: git)
    }

    /// Canonical path resolution matching the Workspace confinement rules:
    /// standardize, then realpath every component so /var vs /private/var
    /// (a firmlink Foundation does not resolve) and symlinked parents cannot
    /// produce divergent identities. Reuses the same helper the tool
    /// confinement boundary relies on.
    static func canonicalize(_ url: URL) -> URL {
        Workspace.resolvingSymlinks(url)
    }
}

/// Reads Git facts for a workspace. Uses the system git binary with a
/// sanitized-ish invocation (fixed argument lists, no shell interpolation,
/// bounded output). Failures degrade to nil fields rather than throwing —
/// a broken repository must not block workspace identity.
enum GitReader {

    static func read(workspaceRoot: URL) -> GitState? {
        guard let topLevel = git(workspaceRoot, ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !topLevel.isEmpty
        else { return nil }

        let repoRootURL = WorkspaceIdentity.canonicalize(URL(fileURLWithPath: topLevel))
        let isWorktree: Bool = {
            var isDirectory: ObjCBool = false
            let gitPath = repoRootURL.appendingPathComponent(".git").path
            guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
                return false
            }
            return !isDirectory.boolValue
        }()

        let branchRaw = git(workspaceRoot, ["rev-parse", "--abbrev-ref", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (branchRaw?.isEmpty == false && branchRaw != "HEAD") ? branchRaw : nil
        let commitRaw = git(workspaceRoot, ["rev-parse", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = commitRaw?.isEmpty == false ? commitRaw : nil
        let rootCommit = git(workspaceRoot, ["rev-list", "--max-parents=0", "HEAD"])?
            .split(separator: "\n").first.map(String.init)
        let remote = git(workspaceRoot, ["config", "--get", "remote.origin.url"])
            .map(normalizeRemote)

        return GitState(
            repositoryRoot: repoRootURL.path,
            branch: branch,
            commit: commit,
            isWorktree: isWorktree,
            remoteURL: remote,
            rootCommit: rootCommit)
    }

    /// Branch/commit refresh without re-deriving identity — used by snapshot
    /// capture, where identity must stay stable across checkouts.
    static func refreshState(workspaceRoot: URL) -> GitState? {
        read(workspaceRoot: workspaceRoot)
    }

    /// Normalizes equivalent remote spellings so identity is stable:
    /// trailing `.git` and slashes removed, scp-style `git@host:path`
    /// converted to `ssh://git@host/path`.
    static func normalizeRemote(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix(".git") { value.removeLast(4) }
        // scp-style syntax: user@host:path → ssh://user@host/path
        if !value.contains("://"), let at = value.firstIndex(of: "@"),
           let colon = value[at...].firstIndex(of: ":") {
            var converted = "ssh://" + value
            converted.replaceSubrange(colon...colon, with: "/")
            value = converted
        }
        return value.lowercased()
    }

    /// Runs git with fixed arguments and bounded output. Never throws.
    static func git(_ root: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        // Never let global config or env rewrite our plumbing commands.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": NSHomeDirectory(),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data.prefix(64 * 1024), as: UTF8.self)
    }
}
