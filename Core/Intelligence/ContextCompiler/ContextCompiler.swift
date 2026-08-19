import Foundation

/// Explicit token budgeting (spec §29). No universal hardcoded context size:
/// the budget derives from the actual model window minus everything else the
/// turn needs.
struct ContextBudget: Sendable, Equatable {
    let contextWindowTokens: Int
    let maxOutputTokens: Int
    let systemPromptTokens: Int
    let conversationTokens: Int
    let safetyMarginTokens: Int

    /// What workspace intelligence may spend this turn.
    var availableWorkspaceTokens: Int {
        max(0, contextWindowTokens - maxOutputTokens - systemPromptTokens
            - conversationTokens - safetyMarginTokens)
    }

    /// Deterministic allocation across packet sections. Capsule has a hard
    /// ceiling per spec §9; the rest splits proportionally.
    func allocation() -> Allocation {
        let available = availableWorkspaceTokens
        let capsule = min(800, available)
        let rest = available - capsule
        return Allocation(
            capsule: capsule,
            knowledge: rest * 25 / 100,
            graph: rest * 30 / 100,
            source: rest * 35 / 100,
            history: rest * 10 / 100)
    }

    struct Allocation: Sendable, Equatable {
        let capsule: Int
        let knowledge: Int
        let graph: Int
        let source: Int
        let history: Int
    }
}

struct AgentTask: Sendable, Equatable {
    let text: String
    /// Explicit @-mentions / file references from the composer.
    let explicitFiles: [String]
    let explicitSymbols: [String]

    init(text: String, explicitFiles: [String] = [], explicitSymbols: [String] = []) {
        self.text = text
        self.explicitFiles = explicitFiles
        self.explicitSymbols = explicitSymbols
    }
}

/// One packed context unit. Every item explains itself (spec §17 UI needs
/// "why included / confidence / freshness / token cost").
struct ContextItem: Sendable, Equatable {
    enum Section: String, Sendable {
        case rules, architecture, decision, pitfall, knowledge
        case symbol, relationship, source, history
    }
    let section: Section
    let id: String
    let text: String
    let whyIncluded: String
    let confidence: String
    let freshness: String
    let estimatedTokens: Int
}

struct SymbolContext: Sendable, Equatable {
    let symbolID: String
    let name: String
    let kind: String
    let path: String
    let startLine: Int?
    let endLine: Int?
    let descriptor: String
}

struct GraphRelationship: Sendable, Equatable {
    let sourceID: String
    let targetID: String
    let kind: String
    let line: Int?
}

struct SourceSnippet: Sendable, Equatable {
    let path: String
    let startLine: Int
    let endLine: Int
    let text: String
    let whyIncluded: String
}

/// The compiled, provider-neutral packet (spec §15). Provider formatters
/// render THIS; they never query the index directly.
struct ContextPacket: Sendable {
    let capsule: ProjectCapsule
    let taskText: String
    var items: [ContextItem]
    var symbols: [SymbolContext]
    var relationships: [GraphRelationship]
    var sources: [SourceSnippet]
    var workingState: WorkingState?
    let estimatedTokens: Int
}

/// The central abstraction (spec §3/§14, Phase 12). Retrieval follows the
/// cascade: explicit anchors → exact symbol → graph neighborhood → lexical →
/// knowledge. Packing is budgeted and every step is deterministic and
/// inspectable — same inputs, same packet.
final class ContextCompiler {

    private let graph: SymbolGraph
    private let search: SearchIndex?
    private let knowledge: KnowledgeStore?
    private let capsuleProvider: () throws -> ProjectCapsule
    private let sourceLoader: (String, Int, Int) -> String?

    init(graph: SymbolGraph,
         search: SearchIndex? = nil,
         knowledge: KnowledgeStore? = nil,
         capsuleProvider: @escaping () throws -> ProjectCapsule,
         sourceLoader: @escaping (String, Int, Int) -> String? = { _, _, _ in nil }) {
        self.graph = graph
        self.search = search
        self.knowledge = knowledge
        self.capsuleProvider = capsuleProvider
        self.sourceLoader = sourceLoader
    }

    static func tokens(_ text: String) -> Int { text.count / 4 }

    func compileContext(
        task: AgentTask, budget: ContextBudget,
        pinnedPacks: Set<ContextPack> = []
    ) throws -> ContextPacket {
        let capsule = try capsuleProvider()
        let allocation = budget.allocation()

        var symbols: [SymbolContext] = []
        var relationships: [GraphRelationship] = []
        var sources: [SourceSnippet] = []
        var items: [ContextItem] = []
        var seenSymbols: Set<String> = []

        // --- Tier 1+2: explicit anchors and exact symbol lookup ----------
        var anchorIDs: [String] = []
        for name in task.explicitSymbols {
            for node in try graph.findSymbols(named: name) {
                anchorIDs.append(node.id)
            }
        }
        for file in task.explicitFiles {
            for node in try graph.symbols(inFile: file) {
                anchorIDs.append(node.id)
            }
        }
        // Task-text symbol mentions (CamelCase / snake identifiers ≥ 5 chars).
        for token in Self.identifierTokens(in: task.text) {
            for node in try graph.findSymbols(named: token) {
                anchorIDs.append(node.id)
            }
        }

        var graphSpend = 0
        for id in anchorIDs where seenSymbols.insert(id).inserted {
            guard graphSpend < allocation.graph else { break }
            guard let node = try graph.node(id: id) else { continue }
            symbols.append(SymbolContext(
                symbolID: node.id, name: node.name,
                kind: node.symbolKind ?? node.kind.rawValue,
                path: node.path ?? "", startLine: node.startLine,
                endLine: node.endLine, descriptor: node.descriptor ?? ""))
            graphSpend += 20 // symbol lines are short; account conservatively

            // --- Tier 3: graph neighborhood (callees + callers, depth 1) ---
            for edge in try graph.outgoingEdges(from: id) + graph.incomingEdges(to: id) {
                guard graphSpend < allocation.graph else { break }
                relationships.append(GraphRelationship(
                    sourceID: edge.source, targetID: edge.target,
                    kind: edge.kind.rawValue, line: edge.line))
                graphSpend += 12
                if let neighbor = try graph.node(id: edge.source == id ? edge.target : edge.source),
                   seenSymbols.insert(neighbor.id).inserted {
                    symbols.append(SymbolContext(
                        symbolID: neighbor.id, name: neighbor.name,
                        kind: neighbor.symbolKind ?? neighbor.kind.rawValue,
                        path: neighbor.path ?? "", startLine: neighbor.startLine,
                        endLine: neighbor.endLine, descriptor: neighbor.descriptor ?? ""))
                    graphSpend += 20
                }
            }
        }

        // --- Tier 5: lexical retrieval for the task text -----------------
        if let search, graphSpend < allocation.graph {
            for hit in try search.search(task.text, kinds: [.symbol], limit: 8) {
                guard let symbolID = hit.symbolID,
                      seenSymbols.insert(symbolID).inserted,
                      let node = try graph.node(id: symbolID) else { continue }
                symbols.append(SymbolContext(
                    symbolID: node.id, name: node.name,
                    kind: node.symbolKind ?? node.kind.rawValue,
                    path: node.path ?? "", startLine: node.startLine,
                    endLine: node.endLine, descriptor: node.descriptor ?? ""))
            }
        }

        // --- Tier 7: knowledge (trust order: decisions/pitfalls first) ---
        if let knowledge {
            var knowledgeSpend = 0
            let all = try knowledge.allRecords()
            // Fresh records only in the packet; stale ones are labeled and
            // capped — never silently trusted (spec: FRESH > STALE).
            let fresh = all.filter { $0.freshness == .fresh }
            let stale = all.filter { $0.freshness != .fresh }
            let taskTokens = Set(Self.identifierTokens(in: task.text).map { $0.lowercased() })

            func relevance(_ record: KnowledgeRecord) -> Int {
                let words = record.scope.lowercased().split(separator: " ").map(String.init)
                    + record.statement.lowercased()
                        .components(separatedBy: .alphanumerics.inverted)
                return words.filter { taskTokens.contains($0) }.count
            }
            func isPinned(_ record: KnowledgeRecord) -> Bool {
                pinnedPacks.contains { $0.knowledgeKinds.contains(record.kind) }
            }

            // Phase 18: pinned packs reweight retrieval — pinned kinds sort
            // first — but the knowledge budget cap below is unchanged. A pin
            // can never grow the packet, only reorder what fills it.
            let ordered = fresh.sorted { lhs, rhs in
                let lhsPinned = isPinned(lhs), rhsPinned = isPinned(rhs)
                if lhsPinned != rhsPinned { return lhsPinned }
                return relevance(lhs) > relevance(rhs)
            }
            for record in ordered {
                guard knowledgeSpend < allocation.knowledge else { break }
                let text = "[\(record.kind.rawValue)] \(record.scope): \(record.statement)"
                let cost = Self.tokens(text)
                knowledgeSpend += cost
                let section: ContextItem.Section = switch record.kind {
                case .decision: .decision
                case .pitfall: .pitfall
                case .architecture: .architecture
                case .convention: .rules
                default: .knowledge
                }
                items.append(ContextItem(
                    section: section, id: record.id, text: text,
                    whyIncluded: isPinned(record)
                        ? "pinned pack (\(record.kind.rawValue))"
                        : relevance(record) > 0
                            ? "matches task terms (\(relevance(record)))"
                            : "fresh \(record.kind.rawValue) in scope",
                    confidence: record.confidence.rawValue,
                    freshness: record.freshness.rawValue,
                    estimatedTokens: cost))
            }
            // Stale knowledge surfaces as a warning, not as fact.
            for record in stale.prefix(3) {
                let text = "STALE \(record.kind.rawValue) (reverify before trusting): \(record.statement)"
                items.append(ContextItem(
                    section: .history, id: record.id, text: text,
                    whyIncluded: "stale after source change",
                    confidence: record.confidence.rawValue,
                    freshness: record.freshness.rawValue,
                    estimatedTokens: Self.tokens(text)))
            }
        }

        // --- Tier 3b: source snippets for anchored symbols ---------------
        var sourceSpend = 0
        for symbol in symbols.prefix(6) {
            guard sourceSpend < allocation.source,
                  let start = symbol.startLine, let end = symbol.endLine,
                  end - start <= 80,
                  let loaded = sourceLoader(symbol.path, start, end) else { continue }
            // Phase 19: snippet text is repository data on its way into a
            // prompt — instruction-like lines are redacted, never executed.
            let text = PromptInjectionSanitizer.sanitize(loaded)
            let cost = Self.tokens(text)
            sourceSpend += cost
            sources.append(SourceSnippet(
                path: symbol.path, startLine: start, endLine: end,
                text: text, whyIncluded: "body of anchored symbol \(symbol.name)"))
        }

        let estimatedTokens = Self.tokens(capsule.rendered())
            + items.reduce(0) { $0 + $1.estimatedTokens }
            + sources.reduce(0) { $0 + Self.tokens($1.text) }
            + symbols.count * 20 + relationships.count * 12

        return ContextPacket(
            capsule: capsule, taskText: task.text, items: items,
            symbols: symbols, relationships: relationships, sources: sources,
            workingState: nil, estimatedTokens: estimatedTokens)
    }

    /// Candidate identifiers in free text: CamelCase words and snake_case
    /// names long enough to be symbol-like.
    static func identifierTokens(in text: String) -> [String] {
        var results: [String] = []
        for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
            let token = String(word)
            let isCamel = token.contains(where: \.isUppercase) && token.count >= 5
            let isSnake = token.contains("_") && token.count >= 5
            if isCamel || isSnake { results.append(token) }
        }
        return results
    }
}
