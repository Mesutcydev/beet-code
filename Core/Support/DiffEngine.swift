import Foundation

/// Line-based diff used to preview file edits before they are applied.
/// Deliberately simple: LCS over lines with a size guard — models of edit
/// previews do not need semantic diffs, they need readable ones.
enum DiffEngine {

    enum LineKind: Sendable, Equatable {
        case context
        case added
        case removed
    }

    struct Line: Sendable, Equatable {
        let kind: LineKind
        let text: String
    }

    struct Result: Sendable, Equatable {
        let lines: [Line]
        var addedCount: Int
        var removedCount: Int

        var isEmpty: Bool { addedCount == 0 && removedCount == 0 }

        var unified: String {
            lines.map { line -> String in
                switch line.kind {
                case .context: return "  \(line.text)"
                case .added: return "+ \(line.text)"
                case .removed: return "- \(line.text)"
                }
            }.joined(separator: "\n")
        }
    }

    static func diff(old: String, new: String) -> Result {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        // Guard against pathological inputs: fall back to whole-file replace.
        if oldLines.count * newLines.count > 4_000_000 {
            return replaceAll(old: oldLines, new: newLines)
        }

        let matrix = lcsTable(oldLines, newLines)
        var lines: [Line] = []
        var added = 0
        var removed = 0

        var i = 0
        var j = 0
        while i < oldLines.count && j < newLines.count {
            if oldLines[i] == newLines[j] {
                lines.append(Line(kind: .context, text: oldLines[i]))
                i += 1
                j += 1
            } else if matrix[i + 1][j] >= matrix[i][j + 1] {
                lines.append(Line(kind: .removed, text: oldLines[i]))
                removed += 1
                i += 1
            } else {
                lines.append(Line(kind: .added, text: newLines[j]))
                added += 1
                j += 1
            }
        }
        while i < oldLines.count {
            lines.append(Line(kind: .removed, text: oldLines[i]))
            removed += 1
            i += 1
        }
        while j < newLines.count {
            lines.append(Line(kind: .added, text: newLines[j]))
            added += 1
            j += 1
        }

        return trimContext(lines: lines, added: added, removed: removed)
    }

    private static func replaceAll(old: [String], new: [String]) -> Result {
        var lines: [Line] = []
        var removed = 0
        var added = 0
        for line in old.prefix(200) {
            lines.append(Line(kind: .removed, text: line))
            removed += 1
        }
        for line in new.prefix(200) {
            lines.append(Line(kind: .added, text: line))
            added += 1
        }
        return Result(lines: lines, addedCount: added, removedCount: removed)
    }

    /// Keeps at most 3 lines of context around changes so previews stay readable.
    private static func trimContext(lines: [Line], added: Int, removed: Int) -> Result {
        let keep = 3
        var keepFlags = [Bool](repeating: false, count: lines.count)
        for (index, line) in lines.enumerated() where line.kind != .context {
            for near in max(0, index - keep)...min(lines.count - 1, index + keep) {
                keepFlags[near] = true
            }
        }
        var trimmed: [Line] = []
        var previousKept = false
        for (index, line) in lines.enumerated() {
            if keepFlags[index] {
                trimmed.append(line)
                previousKept = true
            } else if previousKept {
                trimmed.append(Line(kind: .context, text: "⋯"))
                previousKept = false
            }
        }
        return Result(lines: trimmed, addedCount: added, removedCount: removed)
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = [[Int]](
            repeating: [Int](repeating: 0, count: b.count + 1),
            count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        return table
    }
}
