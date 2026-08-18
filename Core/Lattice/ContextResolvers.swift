import Foundation

/// Real workspace context resolution for the Intent Lattice (Core, pure
/// Foundation — no UI). The store uses these to inject genuine repository
/// state into granted context layers; nothing here is mocked.
public enum ContextResolvers {

    /// Bounded content cap so a huge diff can never blow up the manifest.
    public static let cap = 8_000

    /// Current branch, uncommitted status, and diff stat. Empty when the
    /// workspace is not a repository.
    public static func gitContext(workspace: URL) -> String {
        guard isGitRepo(workspace) else { return "" }
        let branch = gitHead(workspace) ?? "HEAD"
        let status = boundedShell(workspace, ["git", "status", "--short"], cap: 2_000)
        let diff = boundedShell(workspace, ["git", "diff", "--stat"], cap: 4_000)
        var body = "branch: \(branch)\n"
        if !status.isEmpty { body += status + "\n" }
        if !diff.isEmpty { body += diff }
        return String(body.prefix(cap)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lists project documentation files (docs/*.md), capped.
    public static func documentationContext(workspace: URL) -> String {
        let docsDir = workspace.appendingPathComponent("docs", isDirectory: true)
        let names = markdownNames(in: docsDir)
        guard !names.isEmpty else { return "" }
        return "docs/: \(names.prefix(8).joined(separator: ", "))."
    }

    /// Whether the workspace looks like it has test targets (used for
    /// availability — cheap filesystem checks only).
    public static func hasTestTargets(workspace: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: workspace.appendingPathComponent("Tests").path) { return true }
        if let items = try? fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil),
           items.contains(where: { $0.pathExtension == "xcodeproj" }) { return true }
        if let package = try? String(contentsOf: workspace.appendingPathComponent("Package.swift"), encoding: .utf8) {
            return package.contains("testTarget")
        }
        return false
    }

    // MARK: Internals

    static func isGitRepo(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
    }

    static func gitHead(_ root: URL) -> String? {
        let head = root.appendingPathComponent(".git/HEAD")
        guard let raw = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: ") {
            return line.split(separator: "/").last.map(String.init)
        }
        return String(line.prefix(8))
    }

    static func markdownNames(in directory: URL) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "md" }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Short, bounded shell read — availability/probe paths only.
    static func boundedShell(_ root: URL, _ args: [String], cap: Int) -> String {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.prefix(cap)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
