import Foundation

/// Bridges WorkspaceIntelligence into the agent loop. For each task message
/// the provider renders a bounded, clearly-labeled context block from the
/// ContextCompiler; every failure mode (no index, missing stores, compile
/// error) degrades to nil so the intelligence layer can never block or
/// crash a session.
enum IntelligenceContextProvider {

    /// Conservative default: enough for the capsule plus a handful of
    /// knowledge/symbol items, small enough for local-model windows.
    static let budgetTokens = 1_200

    /// Renders the context block for `task`, or nil when the workspace has
    /// no intelligence index (or compilation fails). Never throws.
    static func section(workspaceRoot: URL, task: String) -> String? {
        let identity = WorkspaceIdentity.resolve(root: workspaceRoot)
        guard FileManager.default.fileExists(
            atPath: IntelligenceStoreLayout.graphDatabase(for: identity.workspaceID).path)
        else { return nil }
        let intel = WorkspaceIntelligence(workspaceRoot: workspaceRoot)
        guard let packet = try? intel.context(for: task, budgetTokens: budgetTokens)
        else { return nil }
        return render(packet: packet)
    }

    /// Packet → prompt text. Knowledge and symbols become bullet lines;
    /// snippets are already injection-sanitized by the compiler (Phase 19);
    /// stale knowledge stays visibly labeled.
    static func render(packet: ContextPacket) -> String? {
        var lines: [String] = []
        if packet.capsule.fileCount > 0 {
            lines.append(packet.capsule.rendered())
        }
        for item in packet.items where item.section != .history {
            lines.append("- [\(item.section.rawValue)] \(item.text)")
        }
        for snippet in packet.sources {
            lines.append("- [source] \(snippet.path):\(snippet.startLine)-\(snippet.endLine)\n\(snippet.text)")
        }
        for item in packet.items where item.section == .history {
            lines.append("- \(item.text)") // STALE-prefixed by the compiler
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
