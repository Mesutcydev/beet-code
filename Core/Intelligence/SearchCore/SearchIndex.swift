import Foundation

/// Lexical search over the workspace index (Phase 6). SQLite FTS5 with BM25.
/// This is the honest mid-tier of the retrieval cascade: better than grep
/// for concept lookups, never dressed up as semantic understanding.
/// Embeddings slot in later behind EmbeddingProvider as an EXTENSION —
/// lexical remains the foundational truth layer (spec Phase 6).
final class SearchIndex {

    enum EntryKind: String, Sendable {
        case symbol      // name + descriptor of a parsed symbol
        case fileText    // raw file content (bounded)
        case knowledge   // knowledge store records (Phase 8 writes these)
        case path        // path-only row so filename queries hit
    }

    struct Hit: Sendable, Equatable {
        let kind: EntryKind
        let path: String
        let symbolID: String?
        let snippet: String
        /// BM25 score (lower = better in FTS5); normalized at fusion time.
        let score: Double
    }

    private let store: SQLiteStore

    /// Maximum file text indexed per file — FTS on megabyte blobs helps no one.
    static let maxIndexedTextBytes = 256 * 1024

    init(store: SQLiteStore) throws {
        self.store = store
        try store.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
                content,
                kind UNINDEXED,
                path UNINDEXED,
                symbolID UNINDEXED
            )
            """)
        try store.execute("""
            CREATE TABLE IF NOT EXISTS indexed_files (
                path TEXT PRIMARY KEY,
                contentHash TEXT NOT NULL
            )
            """)
    }

    /// Replaces all FTS rows for one file (symbols + bounded text + path).
    /// Called by the index engine on every upsert.
    func indexFile(_ parsed: ParsedFile, content: String) throws {
        try store.transaction {
            try store.run("DELETE FROM fts WHERE path = ?", bind: { try $0.bind(1, parsed.path) })
            try store.run("DELETE FROM indexed_files WHERE path = ?", bind: { try $0.bind(1, parsed.path) })
            try store.run("INSERT INTO indexed_files (path, contentHash) VALUES (?, ?)") {
                try $0.bind(1, parsed.path)
                try $0.bind(2, parsed.contentHash)
            }

            try store.run("INSERT INTO fts (content, kind, path, symbolID) VALUES (?, ?, ?, ?)") {
                try $0.bind(1, parsed.path)
                try $0.bind(2, EntryKind.path.rawValue)
                try $0.bind(3, parsed.path)
                try $0.bind(4, nil)
            }

            for symbol in parsed.symbols {
                let text = [symbol.name, symbol.kind.rawValue, symbol.descriptor,
                            symbol.typeRelationships.joined(separator: " ")]
                    .joined(separator: " ")
                try store.run("INSERT INTO fts (content, kind, path, symbolID) VALUES (?, ?, ?, ?)") {
                    try $0.bind(1, text)
                    try $0.bind(2, EntryKind.symbol.rawValue)
                    try $0.bind(3, parsed.path)
                    try $0.bind(4, symbol.symbolID)
                }
            }

            let bounded = String(content.utf8.prefix(Self.maxIndexedTextBytes))
            try store.run("INSERT INTO fts (content, kind, path, symbolID) VALUES (?, ?, ?, ?)") {
                try $0.bind(1, bounded)
                try $0.bind(2, EntryKind.fileText.rawValue)
                try $0.bind(3, parsed.path)
                try $0.bind(4, nil)
            }
        }
    }

    /// Indexes an arbitrary knowledge/text record (used by KnowledgeCore).
    func indexKnowledge(id: String, path: String, text: String) throws {
        try store.run("INSERT INTO fts (content, kind, path, symbolID) VALUES (?, ?, ?, ?)") {
            try $0.bind(1, text)
            try $0.bind(2, EntryKind.knowledge.rawValue)
            try $0.bind(3, path)
            try $0.bind(4, id)
        }
    }

    func removeFile(path: String) throws {
        try store.run("DELETE FROM fts WHERE path = ?", bind: { try $0.bind(1, path) })
        try store.run("DELETE FROM indexed_files WHERE path = ?", bind: { try $0.bind(1, path) })
    }

    /// BM25-ranked lexical search. Query syntax is FTS5 MATCH: bare words
    /// AND together; callers quote phrases. Special characters are escaped
    /// into a safe OR-of-terms query.
    func search(_ query: String, kinds: Set<EntryKind>? = nil, limit: Int = 20) throws -> [Hit] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        var hits: [Hit] = []
        let kindFilter: String
        let kindList = (kinds ?? Set(EntryKind.allCases)).map(\.rawValue)
        kindFilter = kindList.map { "'\($0)'" }.joined(separator: ",")
        try store.query("""
            SELECT kind, path, symbolID, snippet(fts, 0, '[', ']', '…', 12), bm25(fts)
            FROM fts WHERE fts MATCH ? AND kind IN (\(kindFilter))
            ORDER BY bm25(fts) LIMIT ?
            """,
            bind: {
                try $0.bind(1, match)
                try $0.bind(2, Int64(limit))
            },
            row: { row in
                hits.append(Hit(
                    kind: EntryKind(rawValue: row.text(0) ?? "fileText") ?? .fileText,
                    path: row.text(1) ?? "",
                    symbolID: row.text(2),
                    snippet: row.text(3) ?? "",
                    score: row.double(4)))
            })
        return hits
    }

    /// Exact symbol lookup — cascade tier 2 (before any fuzzy search).
    func exactSymbol(named name: String) throws -> [Hit] {
        try search("\"\(name)\"", kinds: [.symbol], limit: 10)
            .filter { hit in hit.snippet.contains(name) }
    }

    /// Splits a natural-language query into FTS-safe terms.
    static func tokenize(_ query: String) -> [String] {
        query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }
}

extension SearchIndex.EntryKind: CaseIterable {}

/// Embedding seam (spec §24). Nothing is bundled; when a provider is
/// registered, semantic results fuse with lexical via RankFusion — the
/// lexical layer remains authoritative for exact structural facts.
protocol EmbeddingProvider: Sendable {
    var providerID: String { get }
    func embed(_ text: String) async throws -> [Float]
}

/// Reciprocal Rank Fusion (spec §12): combines result LISTS without
/// pretending their raw scores are comparable. k = 60 is the standard
/// constant from the RRF literature.
enum RankFusion {

    static func fuse<T: Hashable>(_ lists: [[T]], k: Double = 60) -> [(item: T, score: Double)] {
        var scores: [T: Double] = [:]
        for list in lists {
            for (index, item) in list.enumerated() {
                scores[item, default: 0] += 1.0 / (k + Double(index + 1))
            }
        }
        return scores
            .map { (item: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score }
    }
}
