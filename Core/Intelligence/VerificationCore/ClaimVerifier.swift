import Foundation

/// Deterministic structural claim verification (spec §20, Phase 13).
/// Answers come from the CURRENT graph only. Lexical similarity is never
/// dressed up as verification; when the graph can't decide, the result says
/// so and suggests where to look.
struct ClaimVerifier: Sendable {

    enum Verdict: Sendable, Equatable {
        /// The graph positively confirms the claim.
        case verified(evidence: String)
        /// The graph positively contradicts it (subject/object exist, edge absent).
        case false_(reason: String, suggestions: [String])
        /// The index cannot decide (missing symbols, unsupported claim type).
        case unverified(reason: String)
    }

    let graph: SymbolGraph

    init(graph: SymbolGraph) {
        self.graph = graph
    }

    // MARK: Verifications (spec §20 list)

    func symbolExists(_ name: String) throws -> Verdict {
        let matches = try graph.findSymbols(named: name)
        if let first = matches.first {
            return .verified(evidence: "\(name) defined at \(first.path ?? "?"):\(first.startLine ?? 0)")
        }
        return .false_(reason: "no symbol named \(name) in the current index",
                       suggestions: [])
    }

    func callExists(caller: String, callee: String) throws -> Verdict {
        let callers = try graph.findSymbols(named: caller)
        let callees = try graph.findSymbols(named: callee)
        guard !callers.isEmpty else {
            return .unverified(reason: "caller \(caller) not in the index")
        }
        guard !callees.isEmpty else {
            return .unverified(reason: "callee \(callee) not in the index")
        }
        for callerNode in callers {
            for edge in try graph.outgoingEdges(from: callerNode.id, kind: .calls) {
                if callees.contains(where: { $0.id == edge.target }) {
                    return .verified(evidence: "\(caller) calls \(callee) at \(edge.originPath):\(edge.line ?? 0)")
                }
            }
        }
        // Positive contradiction + the likely real callers (spec example).
        var suggestions: [String] = []
        for calleeNode in callees {
            for callerNode in try graph.callers(of: calleeNode.id) {
                suggestions.append("\(callerNode.name) (\(callerNode.path ?? "?"))")
            }
        }
        return .false_(
            reason: "no current call edge from \(caller) to \(callee)",
            suggestions: suggestions)
    }

    func conformanceExists(type: String, protocol proto: String) throws -> Verdict {
        let types = try graph.findSymbols(named: type)
        let protos = try graph.findSymbols(named: proto)
        guard let typeNode = types.first else {
            return .unverified(reason: "type \(type) not in the index")
        }
        guard let protoNode = protos.first else {
            return .unverified(reason: "protocol \(proto) not in the index")
        }
        let edges = try graph.outgoingEdges(from: typeNode.id, kind: .conforms)
        if edges.contains(where: { $0.target == protoNode.id }) {
            return .verified(evidence: "\(type) conforms to \(proto)")
        }
        return .false_(reason: "no conformance edge \(type) → \(proto)",
                       suggestions: [])
    }

    func dependencyExists(file: String, imports module: String) throws -> Verdict {
        let fileNode = try graph.node(id: "file:\(file)")
        guard let fileNode else {
            return .unverified(reason: "file \(file) not in the index")
        }
        let edges = try graph.outgoingEdges(from: fileNode.id, kind: .imports)
        if edges.contains(where: { $0.target == "module:\(module)" }) {
            return .verified(evidence: "\(file) imports \(module)")
        }
        return .false_(reason: "\(file) does not import \(module)",
                       suggestions: edges.map { $0.target.replacingOccurrences(of: "module:", with: "") })
    }

    func fileExists(_ path: String) throws -> Verdict {
        if let node = try graph.node(id: "file:\(path)") {
            return .verified(evidence: "\(path) indexed (\(node.name))")
        }
        return .false_(reason: "\(path) not in the current index", suggestions: [])
    }

    func testCoversSymbol(_ name: String) throws -> Verdict {
        let symbols = try graph.findSymbols(named: name)
        guard !symbols.isEmpty else {
            return .unverified(reason: "symbol \(name) not in the index")
        }
        for symbol in symbols {
            let coverage = try graph.incomingEdges(to: symbol.id, kind: .tests)
            if let first = coverage.first,
               let testNode = try graph.node(id: first.source) {
                return .verified(evidence: "\(name) exercised by \(testNode.name)")
            }
        }
        return .false_(reason: "no test edge into \(name)", suggestions: [])
    }
}
