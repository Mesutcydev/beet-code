import Foundation

/// Phase 15 — deterministic impact analysis. Every number in an
/// ImpactReport comes from actual graph edges and detected entities; no
/// dependency chain is ever invented. Where the graph cannot see something
/// (dynamic dispatch, unresolvable names), the report says so in `evidence`
/// instead of guessing.
struct ImpactReport: Sendable, Equatable {

    enum Risk: String, Sendable, Equatable, Comparable {
        case low, medium, high

        private var rank: Int {
            switch self {
            case .low: 0
            case .medium: 1
            case .high: 2
            }
        }

        static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rank < rhs.rank }
    }

    /// What the report is about, e.g. `AuthService.refreshToken()` or a path.
    let subject: String
    /// Symbols with a direct `calls` edge into the subject set.
    let directCallers: [String]
    /// Derived feature names (Phase 14 directory grouping) that depend on
    /// the subject, excluding the subject's own feature.
    let dependentFeatures: [String]
    /// Test symbols with a `tests` edge into the impacted set.
    let affectedTests: [String]
    /// Security-relevant domains intersecting the impacted set (from
    /// detected entities and deterministic name/path signals).
    let securityDomains: [String]
    let risk: Risk
    /// Human-readable evidence: the actual edges and signals behind every
    /// claim above. Empty claims produce no evidence lines.
    let evidence: [String]

    /// Spec-shaped plain-text rendering (Phase 15 example format).
    var rendered: String {
        var lines: [String] = [
            "Change:", subject, "",
            "Direct callers:", "\(directCallers.count)", "",
        ]
        if !dependentFeatures.isEmpty {
            lines += ["Dependent features:"] + dependentFeatures + [""]
        }
        lines += ["Potentially affected tests:", "\(affectedTests.count)", ""]
        if !securityDomains.isEmpty {
            lines += ["Security domains:"] + securityDomains + [""]
        }
        lines += ["Risk:", risk.rawValue.capitalized]
        if !evidence.isEmpty {
            lines += ["", "Evidence:"] + evidence.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

final class ImpactAnalyzer {

    private let graph: SymbolGraph
    private let entities: EntityStore?

    init(graph: SymbolGraph, entities: EntityStore? = nil) {
        self.graph = graph
        self.entities = entities
    }

    /// Impact of changing a symbol, resolved by name. Multiple same-name
    /// symbols are all included and the ambiguity is recorded as evidence.
    func impact(ofSymbol name: String) throws -> ImpactReport {
        let matches = try graph.findSymbols(named: name)
        guard !matches.isEmpty else {
            return ImpactReport(
                subject: name, directCallers: [], dependentFeatures: [],
                affectedTests: [], securityDomains: [], risk: .low,
                evidence: ["no symbol named '\(name)' in the index — nothing to analyze"])
        }
        var evidence: [String] = []
        if matches.count > 1 {
            evidence.append("'\(name)' is ambiguous (\(matches.count) symbols); analyzing all matches")
        }
        return try report(
            subject: matches.count == 1
                ? "\(matches[0].path ?? ""):\(matches[0].name)"
                : name,
            seeds: Set(matches.map(\.id)),
            baseEvidence: evidence)
    }

    /// Impact of changing a file: everything depending on any symbol in it.
    func impact(ofFile path: String) throws -> ImpactReport {
        let symbols = try graph.symbols(inFile: path)
        guard !symbols.isEmpty else {
            return ImpactReport(
                subject: path, directCallers: [], dependentFeatures: [],
                affectedTests: [], securityDomains: [], risk: .low,
                evidence: ["no indexed symbols in '\(path)'"])
        }
        return try report(subject: path, seeds: Set(symbols.map(\.id)), baseEvidence: [])
    }

    /// Impact of changing a feature (Phase 14 directory grouping): every
    /// symbol in every file under the feature's directory.
    func impact(ofFeature name: String) throws -> ImpactReport {
        guard let entities else {
            return ImpactReport(
                subject: name, directCallers: [], dependentFeatures: [],
                affectedTests: [], securityDomains: [], risk: .low,
                evidence: ["entity store unavailable — features are derived from detected entities"])
        }
        let featurePaths = Set(try entities.allEntities()
            .filter { EntityStore.featureName(forPath: $0.path) == name }
            .map(\.path))
        var seeds: Set<String> = []
        for path in featurePaths {
            seeds.formUnion(try graph.symbols(inFile: path).map(\.id))
        }
        guard !seeds.isEmpty else {
            return ImpactReport(
                subject: name, directCallers: [], dependentFeatures: [],
                affectedTests: [], securityDomains: [], risk: .low,
                evidence: ["no entities or symbols found for feature '\(name)'"])
        }
        return try report(subject: "feature:\(name)", seeds: seeds, baseEvidence: [])
    }

    // MARK: Core

    private func report(
        subject: String, seeds: Set<String>, baseEvidence: [String]
    ) throws -> ImpactReport {
        var evidence = baseEvidence

        // Direct callers: incoming `calls` edges into any seed.
        var callerIDs: Set<String> = []
        for seed in seeds {
            for edge in try graph.incomingEdges(to: seed, kind: .calls) {
                callerIDs.insert(edge.source)
                if let caller = try graph.node(id: edge.source),
                   let target = try graph.node(id: edge.target) {
                    evidence.append(
                        "calls: \(caller.name) → \(target.name) (\(edge.originPath):\(edge.line ?? 0))")
                }
            }
        }

        // Dependents at depth 2 for feature mapping.
        var dependentPaths: Set<String> = []
        var ownPaths: Set<String> = []
        for seed in seeds {
            if let node = try graph.node(id: seed), let path = node.path {
                ownPaths.insert(path)
            }
            let neighborhood = try graph.impactNeighborhood(of: seed, depth: 2)
            for node in neighborhood.nodes where !seeds.contains(node.id) {
                if let path = node.path { dependentPaths.insert(path) }
            }
        }
        let ownFeatures = Set(ownPaths.map { EntityStore.featureName(forPath: $0) })
        let dependentFeatures = Set(dependentPaths
            .map { EntityStore.featureName(forPath: $0) })
            .subtracting(ownFeatures)
            .sorted()

        // Tests exercising anything in the impacted set.
        var testNames: Set<String> = []
        for seed in seeds {
            for edge in try graph.incomingEdges(to: seed, kind: .tests) {
                if let test = try graph.node(id: edge.source) {
                    testNames.insert("\(test.path ?? ""):\(test.name)")
                    evidence.append(
                        "tests: \(test.name) exercises \(try graph.node(id: edge.target)?.name ?? edge.target)")
                }
            }
        }

        // Security domains: entities in impacted files + name/path signals.
        let impactedPaths = ownPaths.union(dependentPaths)
        let securityDomains = try securityDomains(
            seeds: seeds, impactedPaths: impactedPaths, evidence: &evidence)

        let callerNames = try callerIDs.compactMap { try graph.node(id: $0) }
            .map { "\($0.path ?? ""):\($0.name)" }
            .sorted()

        let risk = Self.risk(
            callers: callerIDs.count, tests: testNames.count,
            securityDomains: securityDomains.count)
        evidence.append(
            "risk=\(risk.rawValue) (callers=\(callerIDs.count), tests=\(testNames.count), securityDomains=\(securityDomains.count))")

        return ImpactReport(
            subject: subject,
            directCallers: callerNames,
            dependentFeatures: dependentFeatures,
            affectedTests: testNames.sorted(),
            securityDomains: securityDomains,
            risk: risk,
            evidence: evidence)
    }

    /// Security domain derivation: detected secret/permission/entitlement
    /// entities in impacted files, plus deterministic naming signals
    /// (auth/token/keychain/credential) on seed symbols and their paths.
    private func securityDomains(
        seeds: Set<String>, impactedPaths: Set<String>, evidence: inout [String]
    ) throws -> [String] {
        var domains: Set<String> = []

        if let entities {
            for kind: EntityKind in [.secretReference, .permission, .entitlement] {
                for entity in try entities.entities(ofKind: kind)
                where impactedPaths.contains(entity.path) {
                    let domain: String = switch kind {
                    case .secretReference: "Secrets / credentials"
                    case .permission: "Privacy permissions"
                    case .entitlement: "Sandbox entitlements"
                    default: "Security"
                    }
                    if domains.insert(domain).inserted {
                        evidence.append("security: \(entity.name) (\(entity.path)) → \(domain)")
                    }
                }
            }
        }

        let signals: [(String, String)] = [
            ("auth", "Authentication"), ("token", "Authentication"),
            ("keychain", "Credential persistence"), ("credential", "Credential persistence"),
            ("encrypt", "Cryptography"), ("decrypt", "Cryptography"),
        ]
        for seed in seeds {
            guard let node = try graph.node(id: seed) else { continue }
            let haystack = "\(node.name) \(node.path ?? "")".lowercased()
            for (needle, domain) in signals where haystack.contains(needle) {
                if domains.insert(domain).inserted {
                    evidence.append("security: '\(needle)' signal on \(node.name) → \(domain)")
                }
            }
        }
        return domains.sorted()
    }

    /// Deterministic risk rule (documented, not learned): any security
    /// domain or heavy fan-in/test coverage → high; any callers or tests →
    /// medium; isolated change → low.
    static func risk(callers: Int, tests: Int, securityDomains: Int) -> ImpactReport.Risk {
        if securityDomains > 0 || callers >= 5 || tests >= 5 { return .high }
        if callers > 0 || tests > 0 { return .medium }
        return .low
    }
}
