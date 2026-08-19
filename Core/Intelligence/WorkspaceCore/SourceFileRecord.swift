import Foundation

/// One indexed source unit. The content hash — not path or mtime — is the
/// correctness boundary for freshness and invalidation (spec §7).
struct SourceFileRecord: Codable, Sendable, Equatable {
    /// Workspace-relative POSIX path.
    let relativePath: String
    let sizeBytes: Int64
    /// SHA-256 of file contents. Nil only for files over the hash budget —
    /// such files are recorded (so deletes are tracked) but are excluded
    /// from parsing and freshness-critical knowledge dependencies.
    let contentHash: String?
    let modifiedAt: Date

    /// Files larger than this are not content-hashed (or parsed later).
    /// 64 MB keeps indexing predictable on pathological repositories while
    /// covering every realistic source file.
    static let maxHashableBytes: Int64 = 64 * 1024 * 1024
}

/// Directory ignore rules: built-in exclusions plus nested `.gitignore`
/// semantics. Loaded per-directory during the walk so a nested rule only
/// scopes to its own subtree, matching real Git behavior.
struct IgnoreRules: Sendable, Equatable {

    struct Pattern: Sendable, Equatable {
        /// Directory this pattern was declared in, workspace-relative ("" = root).
        let base: String
        let pattern: String
        let negated: Bool
        let directoryOnly: Bool
        /// True when the pattern contains a non-trailing slash and is thus
        /// anchored to its base directory.
        let anchored: Bool
    }

    private(set) var patterns: [Pattern] = []

    /// Directories never indexed regardless of .gitignore: VCS internals,
    /// build artifacts, vendored dependencies, caches. Superset of
    /// RepoIndexer.excludedNames plus this project's model-weight store.
    static let excludedDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "DerivedData",
        "Build", ".swiftpm", ".venv", "venv", "__pycache__", ".cache",
        "Pods", "Carthage", "vendor", "dist", "build", "out", "target",
        ".idea", ".vscode", ".derived", ".beetcode", "beetcode-models",
        ".workspace-intelligence",
    ]

    init() {}

    /// Parses a .gitignore file located at workspace-relative directory `base`.
    mutating func addGitignore(contents: String, base: String) {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            var negated = false
            var pattern = trimmed
            if pattern.hasPrefix("!") {
                negated = true
                pattern.removeFirst()
            }
            var directoryOnly = false
            if pattern.hasSuffix("/") {
                directoryOnly = true
                pattern.removeLast()
            }
            var anchored = false
            if pattern.hasPrefix("/") {
                anchored = true
                pattern.removeFirst()
            } else if pattern.contains("/") {
                anchored = true
            }
            guard !pattern.isEmpty else { continue }
            patterns.append(Pattern(
                base: base, pattern: pattern,
                negated: negated, directoryOnly: directoryOnly, anchored: anchored))
        }
    }

    /// Last-match-wins evaluation, exactly like gitignore. `relativePath` is
    /// workspace-relative POSIX; `isDirectory` selects directory-only rules.
    func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for rule in patterns where matches(rule, path: relativePath, isDirectory: isDirectory) {
            ignored = !rule.negated
        }
        return ignored
    }

    private func matches(_ rule: Pattern, path: String, isDirectory: Bool) -> Bool {
        if rule.directoryOnly && !isDirectory { return false }

        // Scope: a pattern only applies under its declaring directory.
        var remainder = path
        if !rule.base.isEmpty {
            guard path == rule.base || path.hasPrefix(rule.base + "/") else { return false }
            remainder = path == rule.base ? "" : String(path.dropFirst(rule.base.count + 1))
        }
        guard !remainder.isEmpty else { return false }

        if rule.anchored {
            return Self.globMatch(rule.pattern, remainder)
        }
        // Unanchored: match against the last path component, or any suffix
        // alignment (gitignore semantics for patterns without slashes).
        let components = remainder.split(separator: "/").map(String.init)
        guard let last = components.last else { return false }
        return Self.globMatch(rule.pattern, last)
    }

    /// Glob matcher: `*` within a segment, `?` single char, `**` crosses
    /// directories. Segment-based; no regex compilation per call.
    static func globMatch(_ pattern: String, _ path: String) -> Bool {
        let patternSegments = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return matchSegments(patternSegments, pathSegments)
    }

    private static func matchSegments(_ pattern: [String], _ path: [String]) -> Bool {
        if pattern.isEmpty { return path.isEmpty }
        if pattern[0] == "**" {
            // `**` matches zero or more whole segments.
            for skip in 0...path.count {
                if matchSegments(Array(pattern.dropFirst()), Array(path.dropFirst(skip))) {
                    return true
                }
            }
            return false
        }
        guard let first = path.first, matchSegment(pattern[0], first) else { return false }
        return matchSegments(Array(pattern.dropFirst()), Array(path.dropFirst()))
    }

    private static func matchSegment(_ pattern: String, _ text: String) -> Bool {
        // Iterative wildcard match: `*` → any run within the segment, `?` → one char.
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0, ti = 0, starP = -1, starT = -1
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || (pi < p.count && p[pi] == t[ti]) {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starP = pi; starT = ti; pi += 1
            } else if starP != -1 {
                pi = starP + 1; starT += 1; ti = starT
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
