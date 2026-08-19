import Foundation

/// Semantic concepts beyond functions/classes (spec Phase 14). These are
/// framework/domain-level facts ("this type is a screen", "this URL is an
/// external service") detected DETERMINISTICALLY by framework adapters —
/// never inferred by an LLM. The vocabulary is generic; detection is
/// adapter-driven. A kind with no detecting adapter simply never appears.
enum EntityKind: String, Codable, Sendable, CaseIterable {
    case feature
    case screen
    case endpoint
    case databaseModel
    case migration
    case provider
    case tool
    case capability
    case permission
    case entitlement
    case secretReference
    case buildTarget
    case backgroundTask
    case externalService
}

/// A detected semantic entity. Identity is path+kind+name (NOT line) so the
/// entity survives unrelated edits that shift line numbers.
struct SemanticEntity: Sendable, Equatable {
    /// `ent_` + 10 hex chars of SHA-256 over `path|kind|name`.
    let id: String
    let kind: EntityKind
    let name: String
    /// Workspace-relative path of the file it was detected in.
    let path: String
    let line: Int?
    /// Backing graph symbol when the entity is a declared type.
    let symbolID: String?
    /// Adapter-specific facts (e.g. `stateModel=observableObject`,
    /// `environmentDependencies=appState,settings`). Rendered verbatim in
    /// inspectors — adapters own the vocabulary.
    let attributes: [String: String]
    /// Intelligence provenance, e.g. `swiftui-framework-adapter` (spec §5).
    let source: String

    init(kind: EntityKind, name: String, path: String, line: Int? = nil,
         symbolID: String? = nil, attributes: [String: String] = [:], source: String) {
        self.id = SemanticEntity.makeID(path: path, kind: kind, name: name)
        self.kind = kind
        self.name = name
        self.path = path
        self.line = line
        self.symbolID = symbolID
        self.attributes = attributes
        self.source = source
    }

    static func makeID(path: String, kind: EntityKind, name: String) -> String {
        "ent_" + ContentDigest.sha256Hex("\(path)|\(kind.rawValue)|\(name)").prefix(10)
    }
}

/// Framework-adapter extensibility point (spec Phase 14). Adapters are
/// deterministic and total: a detection failure degrades to fewer entities,
/// never to a failed indexing pass. `parsed` is nil for files with no
/// language adapter (plists, manifests) — content-only detection still runs.
protocol FrameworkAdapter: Sendable {
    var adapterID: String { get }
    func detect(file: SourceFile, parsed: ParsedFile?) -> [SemanticEntity]
}

/// Registered framework adapters. Same registry pattern as ParserRegistry.
enum EntityAdapterRegistry {
    private nonisolated(unsafe) static var adapters: [any FrameworkAdapter] = [
        SwiftUIFrameworkAdapter(),
    ]

    static func register(_ adapter: any FrameworkAdapter) {
        adapters.append(adapter)
    }

    static var registered: [any FrameworkAdapter] { adapters }

    static func detect(file: SourceFile, parsed: ParsedFile?) -> [SemanticEntity] {
        adapters.flatMap { $0.detect(file: file, parsed: parsed) }
    }
}
