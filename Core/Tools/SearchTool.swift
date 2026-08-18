import Foundation

/// Content search: shells out to ripgrep when available (fast, respects
/// .gitignore), falls back to a pure-Swift recursive scan.
struct SearchTool: AgentTool {
    let name = "search"
    let summary = "Search file contents with a regular expression"
    let risk = ToolRisk.read

    // Search spans the whole workspace; a short TTL absorbs duplicate queries
    // in one turn without pretending the tree is frozen.
    let cachePolicy: ToolCachePolicy = .shortLived(5)

    let schemaText = """
        {"type":"object","properties":{
          "pattern":{"type":"string","description":"Regular expression"},
          "path":{"type":"string","description":"File or directory to search (default \".\")"},
          "glob":{"type":"string","description":"Optional file glob filter, e.g. *.swift"}
        },"required":["pattern"]}
        """

    private static let maxMatches = 100
    private static let rgCandidates = [
        "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg",
    ]

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let pattern = call.string("pattern"), !pattern.isEmpty else {
            throw ToolError.missingArgument("pattern")
        }
        let path = call.string("path") ?? "."
        let glob = call.string("glob")
        let url = try context.workspace.resolve(path)

        // Validate the regex up front — an invalid pattern must produce a
        // helpful observation, not a crash.
        _ = try NSRegularExpression(pattern: pattern)

        if let rg = Self.rgCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return try runRipgrep(path: rg, url: url, pattern: pattern, glob: glob)
        }
        return try swiftScan(url: url, pattern: pattern, glob: glob)
    }

    private func runRipgrep(path: String, url: URL, pattern: String, glob: String?) throws -> String {
        var arguments = ["--line-number", "--no-heading", "--max-count", "20", "-e", pattern]
        if let glob {
            arguments += ["--glob", glob]
        }
        arguments.append(url.path)

        // rg on a pathological tree must not hang the loop: hard 20s cap via
        // the shared time-bounded runner.
        guard let result = try? ShellRunner.runProcess(
            executable: path,
            arguments: arguments,
            workingDirectory: url.deletingLastPathComponent(),
            timeout: 20)
        else { return "error: search failed to launch" }
        if result.timedOut {
            return "error: search timed out after 20s"
        }
        let exitCode = result.exitCode
        guard exitCode == 0 || exitCode == 1 else {
            return "error: search failed (rg exit \(exitCode))"
        }
        let output = result.output
        let lines = output.split(separator: "\n")
        guard !lines.isEmpty else { return "(no matches)" }
        return lines.prefix(Self.maxMatches).joined(separator: "\n")
            + (lines.count > Self.maxMatches ? "\n… (truncated at \(Self.maxMatches) matches)" : "")
    }

    private func swiftScan(url: URL, pattern: String, glob: String?) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        var matches: [String] = []
        var isDirectory: ObjCBool = false

        let files: [URL]
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            var collected: [URL] = []
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            while let entry = enumerator?.nextObject() as? URL {
                // Skip excluded directories *and their descendants*, and never
                // descend through symlinks (a link may point outside the root).
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if FileToolsDefaults.skippedNames.contains(entry.lastPathComponent)
                    || values?.isSymbolicLink == true
                {
                    if values?.isDirectory == true || values?.isSymbolicLink == true {
                        enumerator?.skipDescendants()
                    }
                    continue
                }
                if let glob {
                    let name = entry.lastPathComponent
                    guard name.range(of: globToRegex(glob), options: .regularExpression) != nil else {
                        continue
                    }
                }
                collected.append(entry)
            }
            files = collected
        } else {
            files = [url]
        }

        for file in files {
            if matches.count >= Self.maxMatches { break }
            guard let data = try? Data(contentsOf: file), !ReadFileTool.looksBinary(data) else { continue }
            let contents = String(decoding: data, as: UTF8.self)
            let lines = contents.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where matches.count < Self.maxMatches {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    let relative = file.path.replacingOccurrences(of: url.path + "/", with: "")
                    matches.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        guard !matches.isEmpty else { return "(no matches)" }
        return matches.joined(separator: "\n")
    }

    private func globToRegex(_ glob: String) -> String {
        NSRegularExpression.escapedPattern(for: glob)
            .replacingOccurrences(of: "\\*", with: "[^/]*")
    }
}

enum FileToolsDefaults {
    static let skippedNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Build", ".swiftpm",
        ".venv", "__pycache__", ".DS_Store",
    ]
}