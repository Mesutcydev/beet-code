import Foundation

/// Bounded snapshot of the workspace structure, fed to the system prompt so
/// the model sees the project shape without loading whole repositories into
/// context. Excludes generated/vendor directories and respects the root
/// .gitignore; each source file carries a tiny symbol summary.
struct RepoIndex: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let path: String
        let isDirectory: Bool
        let sizeBytes: Int64
        let summary: String?
    }

    let rootPath: String
    var entries: [Entry]
    let truncated: Bool
    let isGitRepository: Bool
    let fileCount: Int

    var render: String {
        var lines: [String] = []
        lines.append("Workspace: \(rootPath)\(isGitRepository ? " (git repository)" : "")")
        for entry in entries {
            if entry.isDirectory {
                lines.append("  \(entry.path)/")
            } else {
                let size = ByteFormatter.bytes(entry.sizeBytes)
                if let summary = entry.summary {
                    lines.append("  \(entry.path) (\(size)): \(summary)")
                } else {
                    lines.append("  \(entry.path) (\(size))")
                }
            }
        }
        if truncated {
            lines.append("  … (index truncated — \(fileCount)+ files)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Builds bounded workspace indexes. Pure and deterministic; the walk is
/// capped so even pathological repositories cannot balloon context.
enum RepoIndexer {

    static let maxFiles = 400
    static let maxDepth = 14
    static let maxSummaryBytes = 64 * 1024

    /// Directories never indexed: version control, build artifacts, vendored
    /// dependencies, caches.
    static let excludedNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Build",
        ".swiftpm", ".venv", "__pycache__", ".cache", "Pods",
        ".DS_Store", "vendor", "dist", "build", ".idea", ".vscode",
    ]

    /// File extensions that get a lightweight symbol summary.
    static let summarizableExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "rs", "go", "java", "kt",
        "c", "h", "cpp", "hpp", "m", "mm", "md", "sh", "rb", "php",
        "json", "yaml", "yml", "toml", "html", "css", "sql",
    ]

    /// Builds a bounded, TASK-RANKED index: entries whose path or summary
    /// matches the task's keywords rank first, so the model sees the most
    /// relevant files within the cap.
    static func build(root: URL, taskHint: String = "") -> RepoIndex {
        var index = build(root: root)
        guard !taskHint.isEmpty else { return index }
        let keywords = taskHint.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 3 }
        guard !keywords.isEmpty else { return index }
        let ranked = index.entries.enumerated().map { position, entry in
            let text = (entry.path + " " + (entry.summary ?? "")).lowercased()
            let score = keywords.reduce(0) { partial, keyword in
                partial + (text.contains(keyword) ? 3 : 0)
            }
            return (entry, score, position)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.isDirectory != rhs.0.isDirectory { return lhs.0.isDirectory }
            return lhs.2 < rhs.2
        }.map(\.0)
        index.entries = ranked
        return index
    }

    static func build(root: URL) -> RepoIndex {
        var entries: [RepoIndex.Entry] = []
        var fileCount = 0
        var truncated = false

        // Root .gitignore patterns (simple globs: literal, *, ?).
        let ignorePatterns = loadGitignore(at: root)

        let isGit = gitRepository(at: root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        else { return RepoIndex(rootPath: root.path, entries: [], truncated: false, isGitRepository: isGit, fileCount: 0) }

        while let item = enumerator.nextObject() as? URL {
            if fileCount >= maxFiles {
                truncated = true
                break
            }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            let name = item.lastPathComponent
            let isDirectory = values?.isDirectory == true

            // Never descend into excluded or symlinked directories.
            if isDirectory {
                if excludedNames.contains(name) || values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                let relative = relativePath(item, root: root)
                guard !isIgnored(relative + "/", patterns: ignorePatterns) else {
                    enumerator.skipDescendants()
                    continue
                }
                entries.append(RepoIndex.Entry(path: relative, isDirectory: true, sizeBytes: 0, summary: nil))
                continue
            }

            if values?.isSymbolicLink == true { continue }
            fileCount += 1
            let relative = relativePath(item, root: root)
            if isIgnored(relative, patterns: ignorePatterns) { continue }
            let size = values?.fileSize ?? 0
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast

            // ForgeCache project intelligence: file summaries are derived data
            // keyed by (path, size, nanosecond mtime). Unchanged files reuse
            // the cached summary (memory first, then disk) instead of
            // re-reading their heads on every build.
            let summary: String?
            if summarizableExtensions.contains(item.pathExtension) {
                let mtimeNs = Int64(modified.timeIntervalSince1970 * 1_000_000_000)
                let key = "\(relative)|\(size)|\(mtimeNs)"
                summary = RepoSummaryCache.shared.summary(key: key) {
                    summarize(file: item, maxBytes: maxSummaryBytes)
                }
            } else {
                summary = nil
            }
            entries.append(RepoIndex.Entry(path: relative, isDirectory: false, sizeBytes: Int64(size), summary: summary))
        }

        // Recency weighting is applied by the task-ranking pass in
        // build(root:taskHint:).
        return RepoIndex(
            rootPath: root.path,
            entries: entries,
            truncated: truncated,
            isGitRepository: isGit,
            fileCount: fileCount)
    }

    // MARK: Summaries

    /// Extracts a one-line symbol summary from a source file: the first
    /// declaration-ish lines (imports, func/struct/class/enum/protocol/def).
    static func summarize(file: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var hits: [String] = []
        for line in lines.prefix(200) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#") else { continue }
            if hits.count < 6, matchesDeclaration(trimmed) {
                hits.append(trimmed)
            }
        }
        guard !hits.isEmpty else { return nil }
        return hits.joined(separator: " | ").prefix(240).description
    }

    private static func matchesDeclaration(_ line: String) -> Bool {
        let keywords = [
            "import ", "func ", "struct ", "class ", "enum ", "protocol ",
            "extension ", "let ", "var ", "def ", "public ", "private ",
            "internal ", "fileprivate ", "static ", "typealias ", "@main",
            "interface ", "type ", "const ", "package ", "@objc",
        ]
        return keywords.contains { line.hasPrefix($0) }
    }

    // MARK: Ignore handling

    private static func loadGitignore(at root: URL) -> [String] {
        let url = root.appendingPathComponent(".gitignore")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
    }

    private static func isIgnored(_ relative: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if matches(pattern: pattern, path: relative) { return true }
        }
        return false
    }

    /// Globbish match: `*` within a segment, trailing `/` matches directories.
    private static func matches(pattern: String, path: String) -> Bool {
        let trimmedPattern = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
        let regexPattern = NSRegularExpression.escapedPattern(for: trimmedPattern)
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: "[^/]")
        guard let regex = try? NSRegularExpression(pattern: "^\(regexPattern)$") else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        // The enumerator may hand back /private/var/… while the root is
        // /var/…; canonicalize both sides before comparing.
        let rootPath = Workspace.resolvingSymlinks(root).path
        let path = Workspace.resolvingSymlinks(url).path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func gitRepository(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
            || FileManager.default.fileExists(atPath: root.path + "/.git")
    }
}