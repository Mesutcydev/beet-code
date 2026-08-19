import Foundation

/// The compact workspace overview (spec §9, Phase 7). Deterministic: every
/// field derives from the snapshot and graph — nothing is summarized by an
/// LLM, nothing is remembered from stale state. Hard-budgeted: the renderer
/// truncates by estimated tokens, so the capsule can never grow into a
/// project dump.
struct ProjectCapsule: Codable, Sendable {
    let projectName: String
    /// Language ID → file count, sorted by count desc.
    let languages: [(language: String, files: Int)]
    /// Top directories by indexed file count — the de-facto module map.
    let structure: [(directory: String, files: Int)]
    /// Most-connected symbols (hubs) — the strongest orientation signal a
    /// graph can offer without prose.
    let hubSymbols: [String]
    let branch: String?
    let commit: String?
    let fileCount: Int
    let symbolCount: Int
    let edgeCount: Int
    let snapshotID: UUID
    let generatedAt: Date
    /// Count of knowledge records currently flagged stale (0 until Phase 8).
    let staleKnowledgeCount: Int

    enum CodingKeys: String, CodingKey {
        case projectName, languages, structure, hubSymbols, branch, commit
        case fileCount, symbolCount, edgeCount, snapshotID, generatedAt
        case staleKnowledgeCount
    }

    /// ~4 chars/token estimate, matching BeetCode's composer heuristic.
    var estimatedTokens: Int { rendered().count / 4 }

    /// Renders within `tokenBudget` (default 800, spec's upper bound).
    /// Sections drop from the bottom up; the header never truncates.
    func rendered(tokenBudget: Int = 800) -> String {
        var sections: [String] = []
        var header = """
        PROJECT CAPSULE
        Project: \(projectName)
        """
        if !languages.isEmpty {
            header += "\nLanguages: " + languages.map { "\($0.language) (\($0.files))" }.joined(separator: ", ")
        }
        if let branch {
            header += "\nGit: \(branch)\(commit.map { " @ " + $0.prefix(8) } ?? "")"
        }
        header += "\nIndex: \(fileCount) files · \(symbolCount) symbols · \(edgeCount) edges"
        if staleKnowledgeCount > 0 {
            header += "\nKnowledge: \(staleKnowledgeCount) stale record\(staleKnowledgeCount == 1 ? "" : "s")"
        }
        sections.append(header)

        if !structure.isEmpty {
            sections.append("Structure:\n" + structure.map { "  \($0.directory)/ (\($0.files) files)" }.joined(separator: "\n"))
        }
        if !hubSymbols.isEmpty {
            sections.append("Core symbols:\n" + hubSymbols.map { "  \($0)" }.joined(separator: "\n"))
        }

        var output = sections[0]
        for section in sections.dropFirst() {
            let candidate = output + "\n\n" + section
            if candidate.count / 4 > tokenBudget { break }
            output = candidate
        }
        return output
    }
}

extension ProjectCapsule {
    // Codable for tuple arrays needs explicit handling.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectName = try c.decode(String.self, forKey: .projectName)
        let langPairs = try c.decode([[String: Int]].self, forKey: .languages)
        languages = langPairs.compactMap { $0.first.map { ($0.key, $0.value) } }
        let dirPairs = try c.decode([[String: Int]].self, forKey: .structure)
        structure = dirPairs.compactMap { $0.first.map { ($0.key, $0.value) } }
        hubSymbols = try c.decode([String].self, forKey: .hubSymbols)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        commit = try c.decodeIfPresent(String.self, forKey: .commit)
        fileCount = try c.decode(Int.self, forKey: .fileCount)
        symbolCount = try c.decode(Int.self, forKey: .symbolCount)
        edgeCount = try c.decode(Int.self, forKey: .edgeCount)
        snapshotID = try c.decode(UUID.self, forKey: .snapshotID)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        staleKnowledgeCount = try c.decode(Int.self, forKey: .staleKnowledgeCount)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectName, forKey: .projectName)
        try c.encode(languages.map { [$0.language: $0.files] }, forKey: .languages)
        try c.encode(structure.map { [$0.directory: $0.files] }, forKey: .structure)
        try c.encode(hubSymbols, forKey: .hubSymbols)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(commit, forKey: .commit)
        try c.encode(fileCount, forKey: .fileCount)
        try c.encode(symbolCount, forKey: .symbolCount)
        try c.encode(edgeCount, forKey: .edgeCount)
        try c.encode(snapshotID, forKey: .snapshotID)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(staleKnowledgeCount, forKey: .staleKnowledgeCount)
    }
}

/// Builds capsules from live index state. Pure: same snapshot + same graph
/// → same capsule (modulo timestamps).
struct CapsuleGenerator: Sendable {

    static func generate(
        identity: WorkspaceIdentity,
        snapshot: WorkspaceSnapshot,
        graph: SymbolGraph,
        staleKnowledgeCount: Int = 0
    ) throws -> ProjectCapsule {
        // Language histogram from parsed files (extension → adapter ID).
        var languageCounts: [String: Int] = [:]
        var directoryCounts: [String: Int] = [:]
        for path in snapshot.files.keys {
            let ext = (path as NSString).pathExtension.lowercased()
            if let adapter = ParserRegistry.adapter(forExtension: ext) {
                languageCounts[adapter.languageID, default: 0] += 1
            } else if !ext.isEmpty {
                languageCounts[ext, default: 0] += 1
            }
            let components = path.split(separator: "/")
            let topDir = components.count > 1 ? String(components[0]) : "(root)"
            directoryCounts[topDir, default: 0] += 1
        }

        let symbolCount = try graph.countNodes()
        let edgeCount = try graph.countEdges()
        let hubs = try graph.hubSymbols(limit: 8)

        return ProjectCapsule(
            projectName: identity.displayName,
            languages: languageCounts.sorted { $0.value > $1.value }.map { (language: $0.key, files: $0.value) },
            structure: directoryCounts.sorted { $0.value > $1.value }.prefix(8).map { (directory: $0.key, files: $0.value) },
            hubSymbols: hubs,
            branch: snapshot.git?.branch,
            commit: snapshot.git?.commit,
            fileCount: snapshot.files.count,
            symbolCount: symbolCount,
            edgeCount: edgeCount,
            snapshotID: snapshot.snapshotID,
            generatedAt: Date(),
            staleKnowledgeCount: staleKnowledgeCount)
    }
}
