import Darwin
import Foundation
import os

/// Risk classification driving the permission system. Reads run automatically;
/// writes and execution require explicit approval unless the user opted into
/// auto-approve. The UI never bypasses this.
enum ToolRisk: Sendable, Equatable {
    /// Inspecting state: read files, list directories, search. Auto-approved.
    case read
    /// Mutating user data: creating or editing files. Approved per action.
    case write
    /// Running processes: shell commands, git mutations. Approved per action.
    case execute

    var label: String {
        switch self {
        case .read: "read"
        case .write: "write"
        case .execute: "execute"
        }
    }

    var requiresApprovalByDefault: Bool {
        self != .read
    }
}

enum ToolError: Error, LocalizedError, Equatable {
    case invalidWorkspaceRoot(String)
    case pathOutsideWorkspace(String)
    case notPreviouslyRead(String)
    case binaryFile(String)
    case fileTooLarge(String, size: Int, limit: Int)
    case missingArgument(String)
    case timeout(Int)
    case commandFailed(exitCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidWorkspaceRoot(let path):
            return "The workspace root is not an accessible directory: '\(path)'."
        case .pathOutsideWorkspace(let path):
            return "Refused to touch '\(path)' — outside the open workspace."
        case .notPreviouslyRead(let path):
            return "Read '\(path)' before editing it."
        case .binaryFile(let path):
            return "'\(path)' looks like a binary file."
        case .fileTooLarge(let path, let size, let limit):
            return "'\(path)' is \(ByteFormatter.bytes(Int64(size))) — larger than the \(ByteFormatter.bytes(Int64(limit))) read limit."
        case .missingArgument(let name):
            return "Missing required argument '\(name)'."
        case .timeout(let seconds):
            return "Command timed out after \(seconds)s."
        case .commandFailed(let code):
            return "Command exited with status \(code)."
        }
    }
}

/// Whether a path will be read or mutated. New-file writes resolve the
/// deepest existing parent so a symlink cannot redirect creation outside.
enum WorkspaceAccess: Sendable {
    case read
    case write
    case enumerate
}

/// A canonical path returned by Workspace. Tools reuse this URL between
/// preview and execution instead of resolving the model-supplied string twice.
struct WorkspacePath: Sendable, Equatable {
    let url: URL
    let relativePath: String
}

/// Confinement boundary for every file operation a tool performs.
struct Workspace: Sendable, Equatable {
    let root: URL
    private let canonicalRoot: URL
    private let validRoot: Bool

    init(root: URL) {
        let standardized = root.standardizedFileURL
        let canonical = Self.resolvingSymlinks(standardized)
        self.root = standardized
        self.canonicalRoot = canonical
        // The root must be a real directory. A root whose *last component* is
        // itself a symlink is rejected (it could be retargeted between calls),
        // while OS-level symlinked prefixes (/var → /private/var, /tmp) are
        // tolerated: the fully-resolved canonical root is the confinement
        // boundary, so containment is still airtight.
        self.validRoot = !Self.isSymlink(standardized.path) && Self.isDirectory(canonical)
    }

    /// Resolves a model-supplied path for a read operation.
    func resolve(_ path: String) throws -> URL {
        try resolve(path, access: .read).url
    }

    /// Resolves a path and verifies canonical containment. Existing paths are
    /// fully realpath-resolved; new writes canonicalize the deepest existing
    /// parent before appending the new components. The returned URL is what
    /// tools must use — never re-resolve the raw model string.
    func resolve(_ path: String, access: WorkspaceAccess) throws -> WorkspacePath {
        // Re-validate the root on EVERY call: the directory could have been
        // deleted and replaced by a symlink (or another directory) mid-session.
        // Failing closed here keeps containment true even under such swaps.
        try validateRoot()

        let expanded = (path as NSString).expandingTildeInPath
        let candidate = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : root.appendingPathComponent(expanded)
        let standardized = candidate.standardizedFileURL

        switch access {
        case .read, .enumerate:
            // Existing paths: resolve every symlink in the path, including
            // intermediate links when the final component does not exist.
            // (URL.resolvingSymlinksInPath silently leaves those unresolved,
            // which would allow a symlink to escape containment.) The result
            // must stay inside the canonical root.
            let canonical = Self.resolvingSymlinks(standardized)
            guard isContained(canonical) else {
                throw ToolError.pathOutsideWorkspace(path)
            }
            return WorkspacePath(url: canonical, relativePath: relativePath(canonical))
        case .write:
            // The final component, when it exists and is a symlink, must not
            // point outside the workspace (writes go to the canonical target).
            let (existingParent, missingComponents) = try deepestExistingParent(standardized)
            let canonicalParent = Self.resolvingSymlinks(existingParent)
            guard isContained(canonicalParent) else {
                throw ToolError.pathOutsideWorkspace(path)
            }
            // Refuse to create a new file *through* a symlinked parent even
            // when the symlink currently resolves inside: a retargeted link
            // would redirect the write. Existing files resolve through the
            // canonical parent (checked above).
            if !missingComponents.isEmpty, Self.isSymlink(existingParent.path) {
                throw ToolError.pathOutsideWorkspace(path)
            }
            let resolved = missingComponents.reduce(canonicalParent) {
                $0.appendingPathComponent($1, isDirectory: false)
            }
            guard isContained(resolved) else {
                throw ToolError.pathOutsideWorkspace(path)
            }
            return WorkspacePath(url: resolved, relativePath: relativePath(resolved))
        }
    }

    /// Per-call root validation: the workspace root must still be a real
    /// directory (not a symlink) whose canonical path matches the boundary
    /// computed at init.
    private func validateRoot() throws {
        guard validRoot else {
            throw ToolError.invalidWorkspaceRoot(root.path)
        }
        guard !Self.isSymlink(root.path),
              Self.isDirectory(canonicalRoot),
              Self.resolvingSymlinks(root).path == canonicalRoot.path
        else {
            throw ToolError.invalidWorkspaceRoot(root.path)
        }
    }

    // MARK: Path resolution

    /// Resolves every symlink in the *existing prefix* of a path and appends
    /// the remaining components verbatim. Unlike URL.resolvingSymlinksInPath,
    /// intermediate symlinks are resolved even when the final component does
    /// not exist — the Foundation method skips resolution in that case, which
    /// would let a workspace-internal symlink escape the confinement check.
    static func resolvingSymlinks(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        var prefix = path
        var suffix: [String] = []
        var depth = 0
        while depth < 64 {
            if let resolved = realpath(prefix) {
                var result = resolved
                for component in suffix {
                    result += "/" + component
                }
                // Raw realpath form (e.g. /private/var/…). isContained and
                // relativePath compare these RAW forms too — mixing raw
                // realpath output with Foundation's /private/var → /var
                // aliasing (applied inconsistently by standardizedFileURL)
                // would produce false negatives.
                return URL(fileURLWithPath: result)
            }
            let parent = (prefix as NSString).deletingLastPathComponent
            guard parent != prefix else { break }
            suffix.insert((prefix as NSString).lastPathComponent, at: 0)
            prefix = parent
            depth += 1
        }
        return URL(fileURLWithPath: path)
    }

    private static func realpath(_ path: String) -> String? {
        path.withCString { cString in
            guard let resolved = Darwin.realpath(cString, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private func isContained(_ url: URL) -> Bool {
        let rootPath = canonicalRoot.path
        let candidatePath = url.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func relativePath(_ url: URL) -> String {
        let rootPath = canonicalRoot.path
        let path = url.path
        guard path != rootPath else { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private static func isSymlink(_ path: String) -> Bool {
        // attributesOfItem follows the link; destinationOfSymbolicLink throws
        // for non-links, so it is the correct lstat-style probe.
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func deepestExistingParent(_ url: URL) throws -> (URL, [String]) {
        var current = url
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                throw ToolError.pathOutsideWorkspace(url.path)
            }
            missing.insert(current.lastPathComponent, at: 0)
            current = parent
        }
        return (current, missing)
    }
}
/// Execution context handed to tools. Knows which files were read this session
/// (write-after-read enforcement) and truncates oversized observations.
final class ToolContext: @unchecked Sendable {
    let workspace: Workspace
    /// Long-term memory for the current workspace (nil when disabled).
    var memory: AgentMemory?
    private let lock = NSLock()
    private var readFiles: Set<String> = []
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    /// Observations longer than this are truncated with a marker.
    static let outputLimit = 16_384

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// Requests cancellation of in-flight tool work (e.g. long commands).
    /// Set by the loop when the user stops the agent mid-tool.
    func requestCancellation() {
        cancelFlag.withLock { $0 = true }
    }

    /// Reset at the start of a new run.
    func clearCancellation() {
        cancelFlag.withLock { $0 = false }
    }

    var isCancellationRequested: Bool {
        cancelFlag.withLock { $0 }
    }

    func noteRead(_ url: URL) {
        lock.lock()
        readFiles.insert(url.path)
        lock.unlock()
    }

    func hasRead(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readFiles.contains(url.path)
    }

    func truncate(_ output: String) -> String {
        guard output.utf8.count > Self.outputLimit else { return output }
        let prefix = String(output.prefix(Self.outputLimit / 2))
        let suffix = String(output.suffix(Self.outputLimit / 4))
        return prefix + "\n…[output truncated]…\n" + suffix
    }
}

/// What a tool shows the user when its call needs approval. Computed before
/// execution so the user always sees exactly what would change.
enum ApprovalPreview: Sendable, Equatable {
    case none
    case command(String)
    case diff(DiffEngine.Result, path: String)
}

/// A capability the agent can invoke. Pure definition + execution; permissions
/// are decided before `execute` is ever called (AgentLoop → PermissionGate →
/// ToolExecutor).
protocol AgentTool: Sendable {
    var name: String { get }
    /// One-line description for approval cards.
    var summary: String { get }
    var risk: ToolRisk { get }
    /// JSON Schema (as text) included in the system prompt.
    var schemaText: String { get }
    /// Result-cache policy (ForgeCache). Default: never.
    var cachePolicy: ToolCachePolicy { get }
    /// Bumped when the tool's behavior changes; part of the action fingerprint.
    var cacheVersion: String { get }

    /// Preview shown when approval is required. Default: nothing.
    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview

    /// Content hashes of the inputs this call's result depends on. Part of the
    /// action fingerprint. Declared in the protocol body (not just the
    /// extension) so conforming tools' implementations dispatch dynamically
    /// through `any AgentTool`; otherwise every tool would statically resolve
    /// to the `[]` default and the cache could never invalidate on edits.
    func cacheInputHashes(for call: ParsedToolCall, in context: ToolContext) -> [String]

    /// Side effects that must still occur when a CACHED result is returned
    /// (e.g. write-after-read bookkeeping). Runs on cache hits only.
    func applyCacheHitSideEffects(for call: ParsedToolCall, in context: ToolContext)

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String
}

extension AgentTool {
    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        .none
    }

    var cachePolicy: ToolCachePolicy { .never }
    var cacheVersion: String { "1" }

    /// Content hashes of the inputs this call's result depends on. Part of the
    /// action fingerprint; tools with stateful inputs return [] (they should
    /// use `.never` or `.shortLived` instead of `.contentAddressed`).
    func cacheInputHashes(for call: ParsedToolCall, in context: ToolContext) -> [String] {
        []
    }

    /// Side effects that must still occur when a CACHED result is returned
    /// (e.g. write-after-read bookkeeping). Runs on cache hits only.
    func applyCacheHitSideEffects(for call: ParsedToolCall, in context: ToolContext) {}
}