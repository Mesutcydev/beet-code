import Foundation

/// Phase 17 — data model behind the Context Inspector UI. Pure assembly
/// from real stores: every number shown in the inspector is computed here
/// from the graph, knowledge store, entity store, and the last compiled
/// ContextPacket. The SwiftUI layer renders this verbatim — no view-side
/// recomputation, nothing decorative.
enum IntelligenceFreshness: String, Sendable, Equatable {
    case fresh, stale, indexing, unavailable

    var label: String {
        switch self {
        case .fresh: "Fresh"
        case .stale: "Stale"
        case .indexing: "Indexing"
        case .unavailable: "Not indexed"
        }
    }
}

/// One inspector domain row (Structure, Architecture, …, Current).
struct DomainSummary: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    /// Headline number (symbols, records, features — domain-dependent).
    let count: Int
    /// Secondary line, e.g. "3 records · 1 stale".
    let detail: String
    let freshness: IntelligenceFreshness
}

/// One line of the "context for current request" breakdown.
struct RequestContextRow: Identifiable, Sendable, Equatable {
    var id: String { label }
    let label: String
    let tokens: Int
}

/// Per-item provenance (spec Phase 17: why included / source / confidence /
/// freshness / token cost).
struct ContextItemDetail: Identifiable, Sendable, Equatable {
    let id: String
    let section: String
    let title: String
    let whyIncluded: String
    let confidence: String
    let freshness: String
    let tokens: Int
}

/// The whole inspector payload.
struct IntelligenceInspectorModel: Sendable, Equatable {
    let projectName: String
    let status: IntelligenceFreshness
    var domains: [DomainSummary]
    var requestRows: [RequestContextRow]
    var requestTotal: Int
    var itemDetails: [ContextItemDetail]
}

enum IntelligenceInspectorBuilder {

    /// Freshness of the intelligence layer as a whole: no snapshot →
    /// unavailable; files changed since the last snapshot → stale;
    /// otherwise fresh. `indexing` is a transient UI state, never derived.
    static func status(
        lastSnapshotAt: Date?, pendingChanges: Int
    ) -> IntelligenceFreshness {
        guard lastSnapshotAt != nil else { return .unavailable }
        return pendingChanges > 0 ? .stale : .fresh
    }

    // MARK: Domains

    /// The twelve spec domains, in display order. Counts and freshness come
    /// from the actual stores; a domain with nothing behind it is reported
    /// as unavailable rather than hidden, so the UI never pretends coverage.
    static func domains(
        graph: SymbolGraph,
        knowledge: KnowledgeStore?,
        entities: EntityStore?,
        workingState: WorkingState?
    ) throws -> [DomainSummary] {
        let records = (try? knowledge?.allRecords()) ?? []
        let allEntities = (try? entities?.allEntities()) ?? []

        func knowledgeDomain(
            _ name: String, kinds: [KnowledgeKind],
            extraCount: Int = 0, extraNoun: String? = nil
        ) -> DomainSummary {
            let matching = records.filter { kinds.contains($0.kind) }
            let stale = matching.filter { $0.freshness != .fresh }.count
            let count = matching.count + extraCount
            var parts: [String] = []
            if !matching.isEmpty {
                parts.append("\(matching.count) record\(matching.count == 1 ? "" : "s")")
            }
            if extraCount > 0, let extraNoun {
                parts.append("\(extraCount) \(extraNoun)")
            }
            if stale > 0 { parts.append("\(stale) stale") }
            return DomainSummary(
                name: name, count: count,
                detail: parts.isEmpty ? "—" : parts.joined(separator: " · "),
                freshness: count == 0 ? .unavailable : (stale > 0 ? .stale : .fresh))
        }

        let nodeCount = (try? graph.countNodes()) ?? 0
        let edgeCount = (try? graph.countEdges()) ?? 0
        let structure = DomainSummary(
            name: "Structure", count: nodeCount,
            detail: nodeCount == 0 ? "—" : "\(nodeCount) nodes · \(edgeCount) edges",
            freshness: nodeCount == 0 ? .unavailable : .fresh)

        let featureCount = (try? entities?.features().count) ?? 0
        let features = DomainSummary(
            name: "Features", count: featureCount,
            detail: featureCount == 0 ? "—" : "\(featureCount) detected",
            freshness: featureCount == 0 ? .unavailable : .fresh)

        let modelCount = allEntities.filter { $0.kind == .databaseModel }.count
        let securityEntityCount = allEntities.filter {
            [.secretReference, .permission, .entitlement].contains($0.kind)
        }.count
        let toolCount = allEntities.filter { $0.kind == .tool }.count

        let current: DomainSummary = {
            guard let workingState else {
                return DomainSummary(name: "Current", count: 0, detail: "—",
                                     freshness: .unavailable)
            }
            let done = workingState.plan.filter { $0.hasPrefix("[x]") }.count
            return DomainSummary(
                name: "Current", count: workingState.touchedFiles.count,
                detail: "\(workingState.branch) · \(workingState.touchedFiles.count) files · \(done)/\(workingState.plan.count) plan",
                freshness: .fresh)
        }()

        return [
            structure,
            knowledgeDomain("Architecture", kinds: [.architecture]),
            knowledgeDomain("Logic", kinds: [.logic]),
            features,
            knowledgeDomain("Data", kinds: [.data], extraCount: modelCount,
                            extraNoun: modelCount == 1 ? "model" : "models"),
            knowledgeDomain("Security", kinds: [.security], extraCount: securityEntityCount,
                            extraNoun: "entities"),
            knowledgeDomain("Capabilities", kinds: [.capability], extraCount: toolCount,
                            extraNoun: toolCount == 1 ? "tool" : "tools"),
            knowledgeDomain("Runtime", kinds: [.runtime]),
            knowledgeDomain("Testing", kinds: [.testing]),
            knowledgeDomain("Decisions", kinds: [.decision]),
            knowledgeDomain("Pitfalls", kinds: [.pitfall]),
            current,
        ]
    }

    // MARK: Current-request breakdown

    /// The spec's "CONTEXT FOR CURRENT REQUEST" table: capsule, session
    /// lifecycle, knowledge sections, symbols, snippets — with per-item
    /// provenance for the detail view.
    static func requestBreakdown(
        packet: ContextPacket
    ) -> (rows: [RequestContextRow], details: [ContextItemDetail], total: Int) {
        var rows: [RequestContextRow] = [
            RequestContextRow(label: "Project Capsule", tokens: packet.capsule.estimatedTokens),
        ]
        if let working = packet.workingState {
            rows.append(RequestContextRow(
                label: "Session lifecycle", tokens: workingStateTokens(working)))
        }

        let sectionLabels: [(ContextItem.Section, String)] = [
            (.rules, "Project rules"),
            (.architecture, "Architecture"),
            (.decision, "Decisions"),
            (.pitfall, "Known pitfall"),
            (.knowledge, "Knowledge"),
            (.relationship, "Graph relationships"),
            (.history, "History"),
        ]
        for (section, label) in sectionLabels {
            let items = packet.items.filter { $0.section == section }
            guard !items.isEmpty else { continue }
            let tokens = items.reduce(0) { $0 + $1.estimatedTokens }
            let name = items.count > 1 && label == "Known pitfall" ? "Known pitfalls" : label
            rows.append(RequestContextRow(label: name, tokens: tokens))
        }

        let symbolItems = packet.items.filter { $0.section == .symbol }
        if !symbolItems.isEmpty {
            rows.append(RequestContextRow(
                label: "\(symbolItems.count) symbol\(symbolItems.count == 1 ? "" : "s")",
                tokens: symbolItems.reduce(0) { $0 + $1.estimatedTokens }))
        }
        let sourceItems = packet.items.filter { $0.section == .source }
        if !sourceItems.isEmpty {
            rows.append(RequestContextRow(
                label: "\(sourceItems.count) source snippet\(sourceItems.count == 1 ? "" : "s")",
                tokens: sourceItems.reduce(0) { $0 + $1.estimatedTokens }))
        }

        let details = packet.items.map { item in
            ContextItemDetail(
                id: item.id,
                section: item.section.rawValue,
                title: item.text.components(separatedBy: "\n").first ?? item.text,
                whyIncluded: item.whyIncluded,
                confidence: item.confidence,
                freshness: item.freshness,
                tokens: item.estimatedTokens)
        }
        return (rows, details, packet.estimatedTokens)
    }

    private static func workingStateTokens(_ state: WorkingState) -> Int {
        let text = ([state.objective] + state.plan + state.touchedFiles
            + state.hypotheses + state.openQuestions + state.failingTests)
            .joined(separator: "\n")
        return max(1, text.count / 4)
    }
}
