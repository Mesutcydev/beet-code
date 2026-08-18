import Foundation

// MARK: - read_file

struct ReadFileTool: AgentTool {
    let name = "read_file"
    let summary = "Read a text file from the workspace with line numbers"
    let risk = ToolRisk.read

    // Keyed by the file's content digest: an unchanged file re-reads from the
    // action cache (skipping decode + line rendering), and any byte change
    // misses automatically.
    let cachePolicy: ToolCachePolicy = .contentAddressed

    func cacheInputHashes(for call: ParsedToolCall, in context: ToolContext) -> [String] {
        guard let path = call.string("path"), !path.isEmpty else { return [] }
        guard let url = try? context.workspace.resolve(path) else { return [] }
        guard let digest = ContentDigest.fileDigest(at: url) else { return [] }
        return [digest]
    }

    func applyCacheHitSideEffects(for call: ParsedToolCall, in context: ToolContext) {
        // A cached read still counts as a read: write-after-read enforcement
        // must hold even when the observation came from the cache.
        guard let path = call.string("path"), !path.isEmpty else { return }
        if let url = try? context.workspace.resolve(path) {
            context.noteRead(url)
        }
    }

    let schemaText = """
        {"type":"object","properties":{
          "path":{"type":"string","description":"Workspace-relative or absolute path"},
          "offset":{"type":"integer","description":"1-based first line to read"},
          "limit":{"type":"integer","description":"Max lines to return (default 800, max 3000)"}
        },"required":["path"]}
        """

    /// Files larger than this are refused outright — loading them into
    /// memory would dominate the model's context for no value.
    static let maxReadBytes = 20 * 1024 * 1024

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let path = call.string("path"), !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        let url = try context.workspace.resolve(path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return "error: file not found: \(path)"
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxReadBytes else {
            throw ToolError.fileTooLarge(path, size: size, limit: Self.maxReadBytes)
        }

        let data = try Data(contentsOf: url)
        if Self.looksBinary(data) {
            throw ToolError.binaryFile(path)
        }

        context.noteRead(url)
        let content = String(decoding: data, as: UTF8.self)
        return Self.render(content: content, offset: call.int("offset") ?? 1, limit: min(call.int("limit") ?? 800, 3000))
    }

    static func render(content: String, offset: Int, limit: Int) -> String {
        let lines = content.components(separatedBy: "\n")
        let start = max(1, offset)
        let end = min(lines.count, start + limit - 1)
        guard start <= end else { return "(empty range)" }

        var rendered: [String] = []
        rendered.reserveCapacity(end - start + 1)
        let gutterWidth = String(end).count
        for index in start...end {
            let line = lines[index - 1]
            rendered.append(String(repeating: " ", count: gutterWidth - String(index).count) + "\(index)→ \(line)")
        }
        if end < lines.count {
            rendered.append("… (\(lines.count - end) more lines)")
        }
        return rendered.joined(separator: "\n")
    }

    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(4096)
        guard !sample.isEmpty else { return false }
        var nonPrintable = 0
        for byte in sample where byte == 0 || (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D) {
            nonPrintable += 1
        }
        return Double(nonPrintable) / Double(sample.count) > 0.1 || sample.contains(0)
    }
}

// MARK: - write_file

struct WriteFileTool: AgentTool {
    let name = "write_file"
    let summary = "Create or completely rewrite a file (read it first if it exists)"
    let risk = ToolRisk.write

    let schemaText = """
        {"type":"object","properties":{
          "path":{"type":"string","description":"Workspace-relative or absolute path"},
          "content":{"type":"string","description":"The COMPLETE new file content"}
        },"required":["path","content"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let path = call.string("path"),
              let content = call.string("content"),
              let url = try? context.workspace.resolve(path, access: .write).url
        else { return .none }
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return .diff(DiffEngine.diff(old: old, new: content), path: path)
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let path = call.string("path"), !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        guard let content = call.string("content") else {
            throw ToolError.missingArgument("content")
        }
        let url = try context.workspace.resolve(path, access: .write).url

        if FileManager.default.fileExists(atPath: url.path), !context.hasRead(url) {
            throw ToolError.notPreviouslyRead(path)
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
        context.noteRead(url)

        let lineCount = content.components(separatedBy: "\n").count
        return "wrote \(path) (\(lineCount) lines)"
    }
}

// MARK: - list_directory

struct ListDirectoryTool: AgentTool {
    let name = "list_directory"
    let summary = "List files in a workspace directory"
    let risk = ToolRisk.read

    // Directory contents change too fast for content addressing to be cheap;
    // a 2-second coalescing window absorbs repeat listings in one turn.
    let cachePolicy: ToolCachePolicy = .shortLived(2)

    let schemaText = """
        {"type":"object","properties":{
          "path":{"type":"string","description":"Directory path (default \".\")"},
          "recursive":{"type":"boolean","description":"Recurse into subdirectories (default false)"}
        },"required":[]}
        """

    private static let skippedNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Build", ".swiftpm",
        ".venv", "__pycache__", ".DS_Store",
    ]

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let path = call.string("path") ?? "."
        let recursive = call.bool("recursive") ?? false
        let url = try context.workspace.resolve(path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return "error: directory not found: \(path)"
        }

        let maxEntries = 500
        var entries: [String] = []

        if recursive {
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isDirectoryKey])
            while let item = enumerator?.nextObject() as? URL {
                if Self.skippedNames.contains(item.lastPathComponent) {
                    enumerator?.skipDescendants()
                    continue
                }
                let relative = item.path.replacingOccurrences(of: url.path + "/", with: "")
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                entries.append(isDir ? relative + "/" : relative)
                if entries.count >= maxEntries { break }
            }
        } else {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in names.sorted() {
                if Self.skippedNames.contains(name) { continue }
                var isDir: ObjCBool = false
                let full = url.appendingPathComponent(name)
                FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
                entries.append(isDir.boolValue ? name + "/" : name)
                if entries.count >= maxEntries { break }
            }
        }

        guard !entries.isEmpty else { return "(empty directory)" }
        return entries.joined(separator: "\n") + (entries.count >= maxEntries ? "\n… (truncated at \(maxEntries) entries)" : "")
    }
}
