import Foundation

/// Phase 19 — trust boundaries for repository-derived text. Everything the
/// intelligence layer reads from a workspace is DATA, never instructions.
/// This sanitizer is the enforcement point: instruction-like lines in
/// repo-derived text are detected and redacted before the text can reach a
/// prompt (source snippets) or the knowledge store (proposals).
struct InjectionFinding: Sendable, Equatable {
    /// 1-based line in the scanned text.
    let line: Int
    /// Which pattern family matched.
    let family: String
}

enum PromptInjectionSanitizer {

    /// Instruction-like patterns. Deliberately conservative: these match
    /// imperative/role-marker phrasing, not prose mentioning prompts.
    private static let rules: [(family: String, pattern: String)] = [
        ("override", #"(?i)\bignore\s+(all|any|the|your)\s+(previous|prior|above|earlier)\b"#),
        ("override", #"(?i)\bdisregard\s+(all|any|the|your)\b"#),
        ("override", #"(?i)\bforget\s+(everything|all|your)\b"#),
        ("persona", #"(?i)\byou\s+are\s+now\b"#),
        ("persona", #"(?i)\bact\s+as\s+(if|a|an)\b.{0,40}\b(ignore|no\s+restrictions|jailbreak)"#),
        ("roleMarker", #"(?im)^\s*(system|assistant|user)\s*:\s"#),
        ("roleMarker", #"<\|?(im_start|im_end|system|endoftext)\|?>"#),
        ("roleMarker", #"\[/?INST\]"#),
        ("exfil", #"(?i)\b(send|post|upload|exfiltrate)\b.{0,40}\b(api\s*key|token|password|secret|credentials)\b"#),
    ]

    static func findings(in text: String) -> [InjectionFinding] {
        var results: [InjectionFinding] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            for rule in rules {
                if line.range(of: rule.pattern, options: .regularExpression) != nil {
                    results.append(InjectionFinding(line: index + 1, family: rule.family))
                    break // one finding per line is enough
                }
            }
        }
        return results
    }

    /// Replaces instruction-like lines with a redaction marker. Structure
    /// (line count, positions) is preserved so line references stay valid.
    static func sanitize(_ text: String) -> String {
        let flagged = Set(findings(in: text).map(\.line))
        guard !flagged.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in
                flagged.contains(index + 1)
                    ? "[redacted: instruction-like content]"
                    : String(line)
            }
            .joined(separator: "\n")
    }
}

/// Phase 19 — path traversal and symlink escape boundary. All intelligence
/// file access must resolve through here: the canonical workspace root is
/// the only legal prefix, after BOTH lexical normalization and realpath
/// resolution of the existing portion.
enum PathSafety {

    /// Resolves `relative` against `root`, rejecting traversal (`..`) and
    /// symlink escapes. Returns the canonical absolute path, or nil when the
    /// path would leave the workspace.
    static func resolve(root: URL, relative: String) -> URL? {
        let canonicalRoot = Workspace.resolvingSymlinks(root).path
        // Manual lexical normalization: both URL.standardizedFileURL and
        // NSString.standardizingPath re-alias /private/var → /var, which
        // would break the raw-prefix comparison against the realpath root.
        var components: [String] = []
        for part in relative.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { return nil } // escapes root
                components.removeLast()
                continue
            }
            components.append(String(part))
        }
        var lexical = canonicalRoot
        for component in components { lexical += "/" + component }
        guard lexical == canonicalRoot || lexical.hasPrefix(canonicalRoot + "/")
        else { return nil }
        let resolved = Workspace.resolvingSymlinks(URL(fileURLWithPath: lexical)).path
        guard resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/")
        else { return nil }
        return URL(fileURLWithPath: resolved)
    }

    static func isWithin(root: URL, relative: String) -> Bool {
        resolve(root: root, relative: relative) != nil
    }
}

/// Phase 19 — binary/oversized content boundary. NUL bytes or invalid UTF-8
/// in the first 8 KB mark a file as binary: tracked in snapshots (existence
/// is a fact) but never parsed or embedded into prompts.
enum BinaryContentDetector {

    static func isLikelyBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        if sample.contains(0) { return true }
        return String(data: Data(sample), encoding: .utf8) == nil
    }
}
