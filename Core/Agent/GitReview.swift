import Foundation

struct GitReviewHunk: Identifiable, Sendable, Equatable {
    enum LineKind: Sendable, Equatable {
        case context
        case added
        case removed
    }

    struct Line: Sendable, Equatable {
        let kind: LineKind
        let text: String
    }

    let id: String
    let header: String
    let oldStart: Int
    let newStart: Int
    let lines: [Line]

    var addedCount: Int { lines.count(where: { $0.kind == .added }) }
    var removedCount: Int { lines.count(where: { $0.kind == .removed }) }

    var oldLines: [String] {
        lines.compactMap { line in
            line.kind == .added ? nil : line.text
        }
    }

    var newLines: [String] {
        lines.compactMap { line in
            line.kind == .removed ? nil : line.text
        }
    }

    var unified: String {
        ([header] + lines.map { line in
            switch line.kind {
            case .context: "  \(line.text)"
            case .added: "+ \(line.text)"
            case .removed: "− \(line.text)"
            }
        }).joined(separator: "\n")
    }
}

struct GitReviewFile: Identifiable, Sendable, Equatable {
    let path: String
    let statusCode: String
    let isStaged: Bool
    let isUntracked: Bool
    let isBinary: Bool
    let diff: DiffEngine.Result
    let hunks: [GitReviewHunk]

    var id: String { path }

    var statusLabel: String {
        if isUntracked { return "New" }
        if statusCode.contains("D") { return "Deleted" }
        if statusCode.contains("R") { return "Renamed" }
        if statusCode.contains("A") { return "Added" }
        return "Modified"
    }
}

enum GitReviewError: Error, LocalizedError {
    case noRepository
    case gitFailed(String)
    case binaryFile(String)
    case hunkNoLongerMatches(String)

    var errorDescription: String? {
        switch self {
        case .noRepository:
            "The open folder is not a Git repository."
        case .gitFailed(let message):
            "Git review failed: \(message)"
        case .binaryFile(let path):
            "Binary file \(path) can be reviewed but not changed by hunk."
        case .hunkNoLongerMatches(let path):
            "The selected hunk no longer matches \(path). Refresh and try again."
        }
    }
}

enum GitReviewService {
    static func load(workspace: URL) throws -> [GitReviewFile] {
        let repository = try git(
            ["rev-parse", "--is-inside-work-tree"],
            workspace: workspace)
        guard repository.exitCode == 0,
              repository.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { throw GitReviewError.noRepository }

        let status = try git(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            workspace: workspace)
        guard status.exitCode == 0 else {
            throw GitReviewError.gitFailed(status.output)
        }

        return try parseStatus(status.output).map { entry in
            try loadFile(entry, workspace: workspace)
        }
    }

    static func reject(
        hunk: GitReviewHunk,
        in file: GitReviewFile,
        workspace: URL
    ) throws {
        guard !file.isBinary else { throw GitReviewError.binaryFile(file.path) }
        let scope = Workspace(root: workspace)
        let fileURL = try scope.resolve(file.path, access: .write).url

        if file.isUntracked, file.hunks.count == 1 {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }

        let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var lines = current.components(separatedBy: "\n")
        let replacement = hunk.oldLines
        let target = hunk.newLines
        let preferred = max(0, min(lines.count, hunk.newStart - 1))

        let match: Int?
        if target.isEmpty {
            match = preferred
        } else if matches(target, in: lines, at: preferred) {
            match = preferred
        } else {
            match = (0...max(0, lines.count - target.count))
                .filter { matches(target, in: lines, at: $0) }
                .min { abs($0 - preferred) < abs($1 - preferred) }
        }
        guard let match else {
            throw GitReviewError.hunkNoLongerMatches(file.path)
        }

        lines.replaceSubrange(match..<(match + target.count), with: replacement)
        let updated = lines.joined(separator: "\n")
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func makeCheckpoint(workspace: URL) throws -> SessionCheckpoint {
        try GitCheckpointer(workspace: Workspace(root: workspace))
            .snapshot(summary: "Before changed-files review")
    }

    static func restore(_ checkpoint: SessionCheckpoint, workspace: URL) throws {
        try GitCheckpointer(workspace: Workspace(root: workspace)).restore(checkpoint)
    }

    static func parseHunks(_ patch: String, path: String) -> [GitReviewHunk] {
        var hunks: [GitReviewHunk] = []
        var header: String?
        var oldStart = 0
        var newStart = 0
        var lines: [GitReviewHunk.Line] = []

        func finish() {
            guard let header else { return }
            let content = ([header] + lines.map(\.text)).joined(separator: "\n")
            hunks.append(GitReviewHunk(
                id: "\(path):\(oldStart):\(newStart):\(ContentDigest.sha256Hex(content))",
                header: header,
                oldStart: oldStart,
                newStart: newStart,
                lines: lines))
        }

        for rawLine in patch.components(separatedBy: "\n") {
            if rawLine.hasPrefix("@@") {
                finish()
                guard let ranges = hunkRanges(rawLine) else {
                    header = nil
                    lines = []
                    continue
                }
                header = rawLine
                oldStart = ranges.old
                newStart = ranges.new
                lines = []
                continue
            }
            guard header != nil, let marker = rawLine.first else { continue }
            let text = String(rawLine.dropFirst())
            switch marker {
            case " ":
                lines.append(.init(kind: .context, text: text))
            case "+":
                lines.append(.init(kind: .added, text: text))
            case "-":
                lines.append(.init(kind: .removed, text: text))
            default:
                break
            }
        }
        finish()
        return hunks
    }
}

private extension GitReviewService {
    struct StatusEntry {
        let code: String
        let path: String
    }

    static func parseStatus(_ output: String) -> [StatusEntry] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true)
        var entries: [StatusEntry] = []
        var index = 0
        while index < records.count {
            let record = String(records[index])
            guard record.count >= 4 else {
                index += 1
                continue
            }
            let code = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            entries.append(StatusEntry(code: code, path: path))
            if code.contains("R") || code.contains("C") {
                index += 2
            } else {
                index += 1
            }
        }
        return entries
    }

    static func loadFile(_ entry: StatusEntry, workspace: URL) throws -> GitReviewFile {
        let isUntracked = entry.code == "??"
        let isStaged = entry.code.first.map { $0 != " " && $0 != "?" } ?? false
        let fileURL = try Workspace(root: workspace).resolve(entry.path, access: .read).url

        let oldResult = try git(["show", "HEAD:\(entry.path)"], workspace: workspace)
        let oldData = oldResult.exitCode == 0 ? Data(oldResult.output.utf8) : Data()
        let newData = (try? Data(contentsOf: fileURL)) ?? Data()
        let isBinary = oldData.contains(0) || newData.contains(0)
            || String(data: oldData, encoding: .utf8) == nil
            || String(data: newData, encoding: .utf8) == nil
        let oldText = String(data: oldData, encoding: .utf8) ?? ""
        let newText = String(data: newData, encoding: .utf8) ?? ""
        let diff = isBinary
            ? DiffEngine.Result(lines: [], addedCount: 0, removedCount: 0)
            : DiffEngine.diff(old: oldText, new: newText)

        var hunks: [GitReviewHunk] = []
        if !isBinary {
            if isUntracked {
                hunks = syntheticHunks(old: oldText, new: newText, path: entry.path)
            } else {
                let patch = try git(
                    ["diff", "HEAD", "--no-ext-diff", "--unified=3", "--", entry.path],
                    workspace: workspace)
                hunks = parseHunks(patch.output, path: entry.path)
                if hunks.isEmpty, !diff.isEmpty {
                    hunks = syntheticHunks(old: oldText, new: newText, path: entry.path)
                }
            }
        }

        return GitReviewFile(
            path: entry.path,
            statusCode: entry.code,
            isStaged: isStaged,
            isUntracked: isUntracked,
            isBinary: isBinary,
            diff: diff,
            hunks: hunks)
    }

    static func syntheticHunks(old: String, new: String, path: String) -> [GitReviewHunk] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let lines = oldLines.map { GitReviewHunk.Line(kind: .removed, text: $0) }
            + newLines.map { GitReviewHunk.Line(kind: .added, text: $0) }
        guard !lines.isEmpty else { return [] }
        let header = "@@ -1,\(oldLines.count) +1,\(newLines.count) @@"
        return [GitReviewHunk(
            id: "\(path):synthetic:\(ContentDigest.sha256Hex(old + "\n" + new))",
            header: header,
            oldStart: 1,
            newStart: 1,
            lines: lines)]
    }

    static func hunkRanges(_ header: String) -> (old: Int, new: Int)? {
        let pattern = #"^@@ -([0-9]+)(?:,[0-9]+)? \+([0-9]+)(?:,[0-9]+)? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: header,
                range: NSRange(header.startIndex..., in: header)),
              let oldRange = Range(match.range(at: 1), in: header),
              let newRange = Range(match.range(at: 2), in: header),
              let old = Int(header[oldRange]),
              let new = Int(header[newRange])
        else { return nil }
        return (old, new)
    }

    static func matches(_ target: [String], in lines: [String], at index: Int) -> Bool {
        guard index >= 0, index + target.count <= lines.count else { return false }
        return Array(lines[index..<(index + target.count)]) == target
    }

    static func git(_ arguments: [String], workspace: URL) throws -> CommandResult {
        try ShellRunner.runProcess(
            executable: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: workspace,
            timeout: 30)
    }
}
