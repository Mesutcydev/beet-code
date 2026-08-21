import Foundation

/// Conservative shell policy. Auto-approval is intentionally limited to exact
/// executable forms; arbitrary shell text remains approval-gated. Enabling
/// auto-approve admits ONLY commands this policy marks safe — it is a
/// safe-command policy, never a blanket shell bypass.
struct CommandPolicy: Sendable {
    struct Decision: Sendable, Equatable {
        let safeForAutoApproval: Bool
        let reason: String?
    }

    /// Executables whose *exact* invocation can be auto-approved when the user
    /// enables safe auto-approve. Everything else requires an approval card.
    private let allowedExecutables: Set<String> = [
        "swift", "xcodebuild", "xcodegen", "ls", "pwd", "wc", "file",
        "git", "rg", "grep", "find", "cat", "head", "tail",
    ]

    /// git subcommands that are inspections, not mutations or remotes.
    private static let readOnlyGit: Set<String> = [
        "status", "diff", "log", "show", "branch", "ls-files",
        "rev-parse", "cat-file", "help", "--version",
    ]

    /// find predicates that write or execute.
    private static let mutatingFind: Set<String> = [
        "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fls",
    ]

    /// Shell syntax that is never auto-approved: separators, substitution,
    /// redirections, backgrounding, heredocs, and newline-separated commands.
    private static let forbiddenTokens: [(String, String)] = [
        (";", "semicolons"), ("&&", "&&"), ("||", "||"), ("|", "pipes"),
        (">", "redirection"), ("<", "redirection"), ("$(", "command substitution"),
        ("`", "backticks"), (String("\n"), "newlines"), (String("\r"), "carriage returns"),
        ("&", "backgrounding"), ("$", "expansion"), ("{", "brace expansion"),
        ("}", "brace expansion"), ("#", "comments"), ("~", "home paths"),
    ]

    func evaluate(_ command: String, workspace: Workspace) -> Decision {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Decision(safeForAutoApproval: false, reason: "empty command") }

        for (token, label) in Self.forbiddenTokens where trimmed.contains(token) {
            return Decision(safeForAutoApproval: false, reason: "shell operator '\(label)' is not auto-approved")
        }

        // Exact-token splitting: `ls-malicious` must never match `ls`.
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let executable = parts.first else {
            return Decision(safeForAutoApproval: false, reason: "missing executable")
        }
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        guard allowedExecutables.contains(executableName) else {
            return Decision(safeForAutoApproval: false, reason: "executable '\(executableName)' requires approval")
        }

        if executableName == "git" {
            guard let subcommand = parts.dropFirst().first, Self.readOnlyGit.contains(subcommand) else {
                return Decision(safeForAutoApproval: false, reason: "git subcommand requires approval")
            }
        }
        if executableName == "find", parts.contains(where: { Self.mutatingFind.contains($0) }) {
            return Decision(safeForAutoApproval: false, reason: "find mutation flag requires approval")
        }

        // Path arguments must resolve inside the workspace — absolute paths,
        // relative traversals (`../`), dot paths, and any path-looking token.
        for argument in parts.dropFirst() {
            let looksLikePath = argument.hasPrefix("/") || argument.hasPrefix("./")
                || argument == "." || argument == ".." || argument.contains("/")
            if looksLikePath {
                guard (try? workspace.resolve(argument, access: .read)) != nil else {
                    return Decision(safeForAutoApproval: false, reason: "path is outside the workspace")
                }
            }
        }

        return Decision(safeForAutoApproval: true, reason: nil)
    }

    /// Whether a command can mutate the workspace — used to decide whether a
    /// checkpoint must precede it. Read-only inspections return false;
    /// anything unknown or ambiguous is treated as potentially mutating.
    func isPotentiallyMutating(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let executable = parts.first else { return false }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        switch name {
        case "ls", "pwd", "wc", "file", "rg", "grep", "cat", "head", "tail":
            return false
        case "find":
            return parts.contains(where: { Self.mutatingFind.contains($0) })
        case "git":
            guard let subcommand = parts.dropFirst().first else { return true }
            return !Self.readOnlyGit.contains(subcommand)
        case "swift", "xcodebuild", "xcodegen":
            // Toolchain commands write build artifacts inside the workspace.
            return true
        default:
            return true
        }
    }
}