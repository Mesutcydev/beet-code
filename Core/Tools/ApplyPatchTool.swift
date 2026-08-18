import Foundation

/// Applies SEARCH/REPLACE edit blocks to a file, character-exact first-match,
/// in order. Supports multiple blocks per call and empty SEARCH (append /
/// create). The patch is computed as a dry-run first so approvals can show a
/// real diff, then written on execute.
struct ApplyPatchTool: AgentTool {
    let name = "apply_patch"
    let summary = "Edit a file with SEARCH/REPLACE blocks (exact character match)"
    let risk = ToolRisk.write

    let schemaText = """
        {"type":"object","properties":{
          "path":{"type":"string","description":"File to edit"},
          "diff":{"type":"string","description":"One or more blocks:\\n<<<<<<< SEARCH\\nexact existing text\\n=======\\nreplacement text\\n>>>>>>> REPLACE"}
        },"required":["path","diff"]}
        """

    enum PatchError: Error, LocalizedError, Equatable {
        case noBlocksFound
        case searchNotFound(block: Int, excerpt: String)
        case malformedBlock(block: Int)

        var errorDescription: String? {
            switch self {
            case .noBlocksFound:
                return "No valid SEARCH/REPLACE blocks found in the diff."
            case .searchNotFound(_, let excerpt):
                return "SEARCH text not found (must match exactly, including whitespace): …\(excerpt)…"
            case .malformedBlock(let block):
                return "Block \(block) is malformed — expected <<<<<<< SEARCH / ======= / >>>>>>> REPLACE."
            }
        }
    }

    struct PatchResult: Equatable {
        let newContent: String
        let appliedBlocks: Int
    }

    // MARK: AgentTool

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let path = call.string("path"),
              let diff = call.string("diff"),
              let url = try? context.workspace.resolve(path, access: .write).url
        else { return .none }
        guard let old = try? String(contentsOf: url, encoding: .utf8) else { return .none }
        guard let result = try? Self.apply(diff: diff, to: old) else { return .none }
        return .diff(DiffEngine.diff(old: old, new: result.newContent), path: path)
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let path = call.string("path"), !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        guard let diff = call.string("diff"), !diff.isEmpty else {
            throw ToolError.missingArgument("diff")
        }
        let url = try context.workspace.resolve(path, access: .write).url

        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists && !context.hasRead(url) {
            throw ToolError.notPreviouslyRead(path)
        }

        let old = exists ? (try String(contentsOf: url, encoding: .utf8)) : ""
        let result = try Self.apply(diff: diff, to: old)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try result.newContent.data(using: .utf8)?.write(to: url, options: .atomic)
        context.noteRead(url)

        return "patched \(path): \(result.appliedBlocks) block(s) applied"
    }

    // MARK: Patch engine (pure, unit-tested)

    /// Applies every block sequentially; throws on the first block whose
    /// SEARCH text cannot be found.
    static func apply(diff: String, to original: String) throws -> PatchResult {
        let blocks = parseBlocks(diff)
        guard !blocks.isEmpty else { throw PatchError.noBlocksFound }

        var content = original
        for (index, block) in blocks.enumerated() {
            content = try applyBlock(block, index: index, to: content)
        }
        return PatchResult(newContent: content, appliedBlocks: blocks.count)
    }

    struct Block: Equatable {
        var search: String
        var replace: String
    }

    static func parseBlocks(_ diff: String) -> [Block] {
        // Tolerate a leading "path" line before the first marker.
        var blocks: [Block] = []
        let lines = diff.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            guard lines[index].hasPrefix("<<<<<<<") else {
                index += 1
                continue
            }
            var search: [String] = []
            var replace: [String] = []
            var phase = 0  // 0 = search, 1 = replace
            var closed = false
            index += 1

            while index < lines.count {
                let line = lines[index]
                if line.hasPrefix("=======") && phase == 0 {
                    phase = 1
                } else if line.hasPrefix(">>>>>>>") && phase == 1 {
                    closed = true
                    index += 1
                    break
                } else if phase == 0 {
                    search.append(line)
                } else {
                    replace.append(line)
                }
                index += 1
            }

            if closed {
                blocks.append(
                    Block(
                        search: search.joined(separator: "\n"),
                        replace: replace.joined(separator: "\n")))
            }
        }
        return blocks
    }

    private static func applyBlock(_ block: Block, index: Int, to content: String) throws -> String {
        if block.search.isEmpty {
            // Empty SEARCH = create (file empty) or append.
            if content.isEmpty { return block.replace }
            return content + "\n" + block.replace
        }
        guard let range = content.range(of: block.search) else {
            let excerpt = String(block.search.prefix(80))
            throw PatchError.searchNotFound(block: index, excerpt: excerpt)
        }
        return content.replacingCharacters(in: range, with: block.replace)
    }
}
