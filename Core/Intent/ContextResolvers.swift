import Foundation

/// Real workspace context resolution for Intent focus sources (Core, pure
/// Foundation — no UI). The composer store uses these to inject genuine
/// repository state into granted focus sources; nothing here is mocked.
public enum ContextResolvers {

    /// Bounded content cap so a huge diff can never blow up the message.
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

    /// Project documentation index: root-level markdown (README, AGENTS, …)
    /// plus docs/*.md, capped. Empty when the project has no docs at all.
    public static func documentationContext(workspace: URL) -> String {
        var parts: [String] = []
        let rootDocs = markdownNames(in: workspace)
        if !rootDocs.isEmpty {
            parts.append(rootDocs.prefix(8).joined(separator: ", "))
        }
        let docsDir = workspace.appendingPathComponent("docs", isDirectory: true)
        let names = markdownNames(in: docsDir)
        if !names.isEmpty {
            parts.append("docs/: \(names.prefix(8).joined(separator: ", "))")
        }
        guard !parts.isEmpty else { return "" }
        return String(parts.joined(separator: " · ").prefix(cap))
    }

    /// A bounded map of the workspace's top-level structure: directories and
    /// files at the root, vendor/build directories excluded. This is an
    /// orientation aid, not an index — the agent's own search tools do the
    /// deep work.
    public static func codebaseContext(workspace: URL) -> String {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: workspace, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return "" }

        let excluded: Set<String> = [
            "node_modules", ".build", ".derived", "DerivedData", "build",
            "dist", "out", "target", ".git", "Pods", "Carthage",
        ]
        var directories: [String] = []
        var files: [String] = []
        for item in items {
            let name = item.lastPathComponent
            guard !excluded.contains(name) else { continue }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                directories.append(name + "/")
            } else {
                files.append(name)
            }
        }
        guard !directories.isEmpty || !files.isEmpty else { return "" }

        var lines: [String] = []
        if !directories.isEmpty {
            lines.append("dirs: \(directories.sorted().prefix(24).joined(separator: " "))")
        }
        if !files.isEmpty {
            lines.append("files: \(files.sorted().prefix(24).joined(separator: " "))")
        }
        return String(lines.joined(separator: "\n").prefix(cap))
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
