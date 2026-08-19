import Foundation

/// Confidence of a parsed fact. ParserCore output is SYNTACTIC: real,
/// deterministic, but not type-checked. Semantic upgrades (LSP/SCIP) arrive
/// in Phase 5 and must be labeled as such — never blended (spec §5).
enum ParserConfidence: String, Codable, Sendable {
    /// Deterministic structural parse of the declaration itself.
    case syntactic
    /// Cross-file/type-checked resolution (LSP/SCIP). Not produced in Phase 2.
    case semantic
}

/// Half-open line range within a source file (1-based lines, inclusive end —
/// human-oriented, matching how editors and diffs report ranges).
struct SourceRange: Codable, Sendable, Equatable {
    let startLine: Int
    let endLine: Int
}

enum SymbolKind: String, Codable, Sendable, CaseIterable {
    case `class`, `struct`, `enum`, `protocol`, `actor`, `extension`
    case function, method, property, initializer, typeAlias
    case test
}

/// A parsed symbol with a stable identity. The descriptor is deterministic
/// (language/scope-chain/name/signature-shape); the internal ID derives from
/// it, so the same symbol re-parsed after unrelated edits keeps its ID.
struct ParsedSymbol: Codable, Sendable, Equatable {
    let name: String
    let kind: SymbolKind
    /// e.g. `swift:Core/Agent/AgentLoop.swift:AgentLoop/run(userMessage:)/async`
    let descriptor: String
    /// `sym_` + 8 hex chars of the descriptor's SHA-256.
    let symbolID: String
    let range: SourceRange
    /// Immediate container's symbolID (type/extension the member belongs to).
    let containerID: String?
    /// Access level keyword when explicit (`public`, `private`, …).
    let access: String?
    /// Notable modifiers, sorted (`async`, `throws`, `static`, `final`, …).
    let modifiers: [String]
    /// Type names from an inheritance/conformance clause, in source order.
    /// Syntactically we cannot distinguish superclass from protocol — the
    /// graph records these as candidate type relationships, not truth.
    let typeRelationships: [String]
    let confidence: ParserConfidence

    static func makeID(descriptor: String) -> String {
        "sym_" + ContentDigest.sha256Hex(descriptor).prefix(8)
    }
}

struct ParsedImport: Codable, Sendable, Equatable {
    let module: String
    let line: Int
}

/// A syntactic call-site or type-mention candidate. NOT a resolved reference:
/// `call` means the text `name(` appears outside a declaration we own.
struct ParsedReference: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case call
        case typeMention
    }
    let name: String
    let kind: Kind
    let line: Int
    /// SymbolID of the innermost symbol containing this line, when known.
    let containerID: String?
}

struct ParsedFile: Codable, Sendable, Equatable {
    /// Workspace-relative path.
    let path: String
    /// Content hash this parse was derived from (freshness dependency).
    let contentHash: String
    let language: String
    var symbols: [ParsedSymbol]
    var imports: [ParsedImport]
    var references: [ParsedReference]
}

/// A source unit handed to an adapter. Content is loaded by the caller.
struct SourceFile: Sendable {
    let path: String
    let content: String
    let contentHash: String
}

/// Extensibility point (spec §24). Adapters must be deterministic and must
/// never fail the indexing pass: parse problems degrade to partial output,
/// never to destroyed prior intelligence.
protocol LanguageAdapter: Sendable {
    /// Language identifier used in descriptors, e.g. `swift`.
    var languageID: String { get }
    /// Lowercased file extensions this adapter handles (no dot).
    var fileExtensions: Set<String> { get }
    func parse(file: SourceFile) -> ParsedFile
}

/// Extension → adapter registry. Unknown extensions parse to empty results
/// with language "unknown" — recorded honestly, never guessed.
enum ParserRegistry {
    private nonisolated(unsafe) static var adapters: [any LanguageAdapter] = [
        SwiftLanguageAdapter(),
    ]

    static func register(_ adapter: any LanguageAdapter) {
        adapters.append(adapter)
    }

    static func adapter(forExtension ext: String) -> (any LanguageAdapter)? {
        let lower = ext.lowercased()
        return adapters.first { $0.fileExtensions.contains(lower) }
    }

    /// Parse one file, routing by extension. Returns nil for unsupported
    /// types — the caller records the file as unindexed, not as empty.
    static func parse(file: SourceFile) -> ParsedFile? {
        let ext = (file.path as NSString).pathExtension
        guard let adapter = adapter(forExtension: ext) else { return nil }
        return adapter.parse(file: file)
    }
}
