import Foundation

/// What an agent submits when it believes it learned something durable
/// (spec §17). Agents NEVER write to KnowledgeStore directly — every fact
/// passes through KnowledgePipeline.
struct KnowledgeProposal: Sendable, Equatable {
    let kind: KnowledgeKind
    let scope: String
    let statement: String
    /// Paths the agent cites as support. Hashes are attached by the pipeline
    /// from the CURRENT index — agents cannot self-certify evidence.
    let evidencePaths: [String]
    /// Optional symbol names the claim depends on; the pipeline verifies
    /// they exist in the live graph.
    let evidenceSymbols: [String]
    let branchScope: String?
    /// Who proposed: "agent", "user", "import" — drives confidence ceiling.
    let origin: String
}

enum KnowledgeProposalResult: Sendable, Equatable {
    case committed(id: String, confidence: KnowledgeConfidence)
    case duplicate(existingID: String)
    case rejected(reason: String)
    /// Conflicts with an existing record in the same scope — held for human
    /// or higher-confidence resolution, never silently overwritten.
    case conflict(existingID: String)
}

/// The write gate for durable knowledge (spec §17, Phase 9):
/// classification → dedup → secret scan → evidence attachment → freshness
/// check → graph verification → conflict detection → scope → confidence →
/// commit. Every step is deterministic and every rejection states why.
final class KnowledgePipeline: @unchecked Sendable {

    private let store: KnowledgeStore
    private let graph: SymbolGraph
    /// Supplies current content hashes for evidence attachment: path → hash
    /// (nil = file absent from the index).
    private let hashProvider: (String) -> String?
    private let gitCommitProvider: () -> String?

    init(store: KnowledgeStore,
         graph: SymbolGraph,
         hashProvider: @escaping (String) -> String?,
         gitCommitProvider: @escaping () -> String? = { nil }) {
        self.store = store
        self.graph = graph
        self.hashProvider = hashProvider
        self.gitCommitProvider = gitCommitProvider
    }

    func propose(_ proposal: KnowledgeProposal) throws -> KnowledgeProposalResult {
        // 1. Classification sanity: statement must say something.
        let statement = proposal.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard statement.count >= 12 else {
            return .rejected(reason: "statement too short to be durable knowledge")
        }

        // 2. Secret scan — nothing secret-shaped ever enters the store.
        if let leak = SecretScanner.firstMatch(in: statement) {
            return .rejected(reason: "proposal contains secret-shaped content: \(leak)")
        }

        // 2b. Injection scan (Phase 19) — knowledge statements become prompt
        // content later, so instruction-like text is a hostile proposal,
        // not a fact.
        if let finding = PromptInjectionSanitizer.findings(in: statement).first {
            return .rejected(reason: "proposal contains instruction-like content (\(finding.family))")
        }

        // 3. Deduplication: same kind+scope+normalized statement.
        let existing = try store.records(kind: proposal.kind, scope: proposal.scope)
        let normalized = Self.normalize(statement)
        if let dupe = existing.first(where: { Self.normalize($0.statement) == normalized }) {
            return .duplicate(existingID: dupe.id)
        }

        // 4+5. Evidence attachment with CURRENT hashes + freshness check.
        var evidence: [Evidence] = []
        for path in proposal.evidencePaths {
            guard let hash = hashProvider(path) else {
                return .rejected(reason: "evidence path not in the index: \(path)")
            }
            evidence.append(Evidence(
                path: path, symbolID: nil, startLine: nil, endLine: nil,
                contentHash: hash, gitCommit: gitCommitProvider(), capturedAt: Date()))
        }

        // 6. Graph verification: cited symbols must exist NOW.
        var verifiedSymbolCount = 0
        for name in proposal.evidenceSymbols {
            let matches = try graph.findSymbols(named: name)
            guard let symbol = matches.first else {
                return .rejected(reason: "cited symbol not found in current index: \(name)")
            }
            verifiedSymbolCount += 1
            if let path = symbol.path, let hash = hashProvider(path) {
                evidence.append(Evidence(
                    path: path, symbolID: symbol.id,
                    startLine: symbol.startLine, endLine: symbol.endLine,
                    contentHash: hash, gitCommit: gitCommitProvider(), capturedAt: Date()))
            }
        }
        // 7. Conflict detection: same kind+scope, materially different
        // statement → hold, don't overwrite (spec: conflict detection).
        if let conflict = existing.first(where: {
            Self.normalize($0.statement) != normalized
            && Self.overlaps($0.statement, statement)
        }) {
            return .conflict(existingID: conflict.id)
        }

        // 8+9. Scope + confidence: evidence-backed symbol-verified claims
        // earn .verified; file-only evidence .inferred; user origin at least
        // .userProvided; imports .historical. Confidence never exceeds what
        // the evidence supports.
        let confidence: KnowledgeConfidence
        switch proposal.origin {
        case "user":
            confidence = evidence.isEmpty ? .userProvided : .verified
        case "import":
            confidence = .historical
        default:
            if verifiedSymbolCount > 0, !evidence.isEmpty {
                confidence = .verified
            } else if !evidence.isEmpty {
                confidence = .inferred
            } else {
                // Unsupported agent claims never persist (spec §17).
                return .rejected(reason: "no verifiable evidence attached")
            }
        }

        let id = "kn_" + ContentDigest.sha256Hex(
            "\(proposal.kind.rawValue)|\(proposal.scope)|\(normalized)").prefix(10)
        let record = KnowledgeRecord(
            id: id, kind: proposal.kind, scope: proposal.scope,
            statement: statement, confidence: confidence,
            freshness: .fresh, evidence: evidence,
            branchScope: proposal.branchScope,
            createdAt: Date(), updatedAt: Date())
        try store.insert(record)
        return .committed(id: id, confidence: confidence)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Cheap deterministic conflict proxy: records in the same kind+scope
    /// sharing most content words but differing in polarity keywords are
    /// likely contradictions ("supports streaming" vs "does not support…").
    static func overlaps(_ a: String, _ b: String) -> Bool {
        let wordsA = Set(normalize(a).split(separator: " "))
        let wordsB = Set(normalize(b).split(separator: " "))
        let shared = wordsA.intersection(wordsB).count
        let polarity: Set<Substring> = ["not", "never", "no", "removed", "deprecated", "unsupported"]
        let polarityDiffers = !wordsA.intersection(polarity).isEmpty
            || !wordsB.intersection(polarity).isEmpty
        return shared >= 3 && polarityDiffers
    }
}

/// Deterministic secret detection for memory proposals (spec §21). Catches
/// the common credential shapes; the point is to never persist them, not to
/// be a general DLP.
enum SecretScanner {

    static let patterns: [(name: String, regex: String)] = [
        ("AWS access key", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("private key block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        ("OpenAI-style key", #"\bsk-[A-Za-z0-9]{20,}\b"#),
        ("bearer token", #"(?i)bearer\s+[A-Za-z0-9._\-]{20,}"#),
        ("password assignment", #"(?i)(password|passwd|secret|api[_-]?key)\s*[:=]\s*\S{6,}"#),
        ("generic long hex secret", #"(?i)(token|secret)\s*[:=]\s*[0-9a-f]{32,}"#),
    ]

    /// Returns the name of the first matching secret pattern, or nil.
    static func firstMatch(in text: String) -> String? {
        for pattern in patterns {
            if text.range(of: pattern.regex, options: .regularExpression) != nil {
                return pattern.name
            }
        }
        return nil
    }
}
