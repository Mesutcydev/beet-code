import Foundation
import os

/// One normalized compiler diagnostic.
struct Diagnostic: Sendable, Equatable, Identifiable {
    enum Severity: String, Sendable, Equatable, Comparable {
        case error
        case warning
        case note

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            rank(lhs) < rank(rhs)
        }

        private static func rank(_ severity: Severity) -> Int {
            switch severity {
            case .error: 0
            case .warning: 1
            case .note: 2
            }
        }
    }

    let file: String
    let line: Int?
    let column: Int?
    let severity: Severity
    let message: String

    var id: String { "\(file):\(line ?? 0):\(column ?? 0):\(message)" }
}

/// Parses Swift/Xcode compiler output into normalized diagnostics. Handles
/// the common `file:line:column: severity: message` shape; anything that
/// does not match is surfaced as a raw line so no information is lost.
enum DiagnosticParser {

    /// `path/file.swift:12:34: error: message` (Swift, xcodebuild, swiftc).
    private static let pattern =
        #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.*)$"#

    static func parse(_ output: String) -> [Diagnostic] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var diagnostics: [Diagnostic] = []
        for line in output.split(separator: "\n") {
            let line = String(line)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 6,
                  let fileRange = Range(match.range(at: 1), in: line),
                  let lineRange = Range(match.range(at: 2), in: line),
                  let columnRange = Range(match.range(at: 3), in: line),
                  let severityRange = Range(match.range(at: 4), in: line),
                  let messageRange = Range(match.range(at: 5), in: line)
            else { continue }
            diagnostics.append(
                Diagnostic(
                    file: String(line[fileRange]),
                    line: Int(line[lineRange]),
                    column: Int(line[columnRange]),
                    severity: Diagnostic.Severity(rawValue: String(line[severityRange])) ?? .note,
                    message: String(line[messageRange])))
        }
        return diagnostics
    }

    /// Renders diagnostics for the agent, bounded and grouped by severity.
    static func render(_ diagnostics: [Diagnostic], maxLines: Int = 200) -> String {
        guard !diagnostics.isEmpty else {
            return "Checks completed with no compiler diagnostics."
        }
        let errors = diagnostics.filter { $0.severity == .error }
        let warnings = diagnostics.filter { $0.severity == .warning }
        var lines: [String] = []
        lines.append("Diagnostics: \(errors.count) error(s), \(warnings.count) warning(s), \(diagnostics.count - errors.count - warnings.count) note(s)")
        for diagnostic in diagnostics.prefix(maxLines) {
            let location = [diagnostic.file, diagnostic.line.map(String.init) ?? "?",
                            diagnostic.column.map(String.init) ?? "?"].joined(separator: ":")
            lines.append("\(diagnostic.severity.rawValue): \(location): \(diagnostic.message)")
        }
        if diagnostics.count > maxLines {
            lines.append("… \(diagnostics.count - maxLines) more diagnostics omitted")
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs the project's build/test and returns normalized diagnostics so the
/// loop can repair the previous edit. Execution goes through the SAME
/// permission path as any command — it never silently runs arbitrary
/// commands.
struct BuildDiagnosticsTool: AgentTool, CommandExecuting {
    let name = "build_diagnostics"
    let summary = "Run the detected project checks and return parsed diagnostics"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "command":{"type":"string","description":"Optional check command. The default detects the project and runs its build or tests."},
          "path":{"type":"string","description":"Optional project directory (default: workspace root)"}
        },"required":[]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let command = call.string("command") ?? "auto (detected build/test checks)"
        return .command(command)
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let result = try await executeCommand(call, in: context)
        return Self.render(result)
    }

    func executeCommand(_ call: ParsedToolCall, in context: ToolContext) async throws -> CommandResult {
        let command = call.string("command") ?? Self.defaultCommand(in: {
            if let path = call.string("path"),
               let resolved = try? context.workspace.resolve(path, access: .read) {
                return resolved.url
            }
            return context.workspace.root
        }())
        guard !command.isEmpty else { throw ToolError.missingArgument("command") }

        // Resolve the project directory through the workspace authority.
        let directory: URL
        if let path = call.string("path") {
            directory = try context.workspace.resolve(path, access: .read).url
        } else {
            directory = context.workspace.root
        }

        // Run through the same cancellation-aware runner as run_command.
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            // .userInitiated to match the awaiting task's QoS (see the same
            // fix in RunCommandTool — a .utility detached task caused a
            // priority-inversion warning whose inline symbolication wedged
            // the waiter).
            try await Task.detached(priority: .userInitiated) {
                try ShellRunner.run(
                    command: command,
                    workingDirectory: directory,
                    timeout: 600,
                    cancelCheck: {
                        cancelled.withLock { $0 } || context.isCancellationRequested
                    })
            }.value
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Renders the raw output plus the normalized diagnostics.
    static func render(_ result: CommandResult) -> String {
        let diagnostics = DiagnosticParser.parse(result.output)
        var sections: [String] = [DiagnosticParser.render(diagnostics)]
        if result.timedOut {
            sections.append("error: build timed out")
        } else if result.exitCode != 0 {
            sections.append("exit status \(result.exitCode)")
        }
        let raw = RunCommandTool.truncate(result.output, limit: 24_000)
        sections.append("raw output:\n\(raw)")
        return sections.joined(separator: "\n")
    }

    /// Pick the safest useful check for the project. A test action includes a
    /// build, so it is preferred when test sources are present; otherwise we
    /// avoid failing a perfectly valid app that has no test target.
    static func defaultCommand(in directory: URL) -> String {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let action = hasTestSources(in: directory) ? "test" : "build"
        if let workspace = kids.first(where: { $0.pathExtension == "xcworkspace" }) {
            let name = workspace.deletingPathExtension().lastPathComponent
            return "xcodebuild -workspace \(shellQuote(name + ".xcworkspace")) -scheme \(shellQuote(name)) -destination 'platform=macOS' \(action)"
        }
        if let proj = kids.first(where: { $0.pathExtension == "xcodeproj" }) {
            let name = proj.deletingPathExtension().lastPathComponent
            return "xcodebuild -project \(shellQuote(name + ".xcodeproj")) -scheme \(shellQuote(name)) -destination 'platform=macOS' \(action)"
        }
        let yml = directory.appendingPathComponent("project.yml")
        if fm.fileExists(atPath: yml.path) {
            let product = projectName(fromYML: yml) ?? "App"
            return "xcodegen generate && xcodebuild -project \(shellQuote(product + ".xcodeproj")) -scheme \(shellQuote(product)) -destination 'platform=macOS' \(action)"
        }
        if fm.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            return hasTestSources(in: directory) ? "swift test" : "swift build"
        }
        return "swift build"
    }

    /// Test targets are deliberately detected from the source tree rather
    /// than inferred from the project name. This keeps generated apps without
    /// tests buildable while making SPM/Xcode test suites part of verification
    /// as soon as the user adds them.
    private static func hasTestSources(in directory: URL) -> Bool {
        let fm = FileManager.default
        let directTestDirectories = ["Tests", "Test", "BeetCodeTests"]
            .map { directory.appendingPathComponent($0) }
            .contains { url in
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        if directTestDirectories { return true }

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return false }

        for case let url as URL in enumerator {
            let path = url.path
            if path.contains("/.build/") || path.contains("/DerivedData/") || path.contains("/node_modules/") {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "swift",
               url.deletingPathExtension().lastPathComponent.hasSuffix("Tests") {
                return true
            }
        }
        return false
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func projectName(fromYML url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("name:") else { continue }
            let value = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }
}
