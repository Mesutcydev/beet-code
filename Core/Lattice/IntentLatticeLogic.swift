import Foundation

// MARK: - Presets

/// Real presets mapping to concrete role/context selections. Applying a
/// preset skips cells whose context layer is currently unavailable, with a
/// visible report — it never silently selects an unprovidable capability.
public struct LatticePreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let glyph: String
    public let summary: String
    public let cells: [LatticeCellID]

    public init(id: String, name: String, glyph: String, summary: String, cells: [LatticeCellID]) {
        self.id = id; self.name = name; self.glyph = glyph; self.summary = summary
        self.cells = cells
    }

    /// Applies the preset against live availability. Returns the applied
    /// selections plus the skipped cells with reasons (shown in the UI).
    public func apply(availability: (ContextLayer) -> CellAvailability)
        -> (configuration: LatticeConfiguration, skipped: [(cell: LatticeCellID, reason: String)]) {
        var cells: [String: LatticeCellSelection] = [:]
        var skipped: [(LatticeCellID, String)] = []
        for cellID in self.cells {
            if case .unavailable(let reason, _) = availability(cellID.context) {
                skipped.append((cellID, "\(cellID.context.label): \(reason)"))
            } else {
                cells[cellID.key] = LatticeCellSelection(id: cellID, weight: 1.0, source: .preset)
            }
        }
        return (LatticeConfiguration(cells: cells, presetID: id), skipped)
    }
}

public enum LatticePresets {

    public static let all: [LatticePreset] = [
        LatticePreset(
            id: "balanced-build", name: "Balanced Build", glyph: "square.stack.3d.up",
            summary: "Full pipeline: plan, build, review, verify against the repo.",
            cells: [
                .init(.orchestrator, .codebase),
                .init(.planner, .codebase), .init(.planner, .documentation),
                .init(.builder, .openFiles), .init(.builder, .codebase),
                .init(.builder, .terminal), .init(.builder, .git),
                .init(.reviewer, .codebase), .init(.reviewer, .git),
                .init(.tester, .tests), .init(.tester, .terminal),
            ]),
        LatticePreset(
            id: "fast-edit", name: "Fast Edit", glyph: "bolt",
            summary: "Minimal context for a quick, focused edit.",
            cells: [
                .init(.builder, .openFiles), .init(.builder, .codebase),
            ]),
        LatticePreset(
            id: "debug-verify", name: "Debug & Verify", glyph: "ant",
            summary: "Investigate a failure, fix it, prove it with tests.",
            cells: [
                .init(.planner, .codebase), .init(.planner, .git),
                .init(.builder, .codebase), .init(.builder, .terminal),
                .init(.tester, .tests), .init(.tester, .terminal),
            ]),
        LatticePreset(
            id: "code-review", name: "Code Review", glyph: "checkmark.seal",
            summary: "Read-only review of the current changes.",
            cells: [
                .init(.reviewer, .openFiles), .init(.reviewer, .codebase),
                .init(.reviewer, .git), .init(.reviewer, .tests),
            ]),
        LatticePreset(
            id: "research-first", name: "Research First", glyph: "magnifyingglass",
            summary: "Understand the area before proposing anything.",
            cells: [
                .init(.researcher, .codebase), .init(.researcher, .documentation),
                .init(.researcher, .memory),
                .init(.planner, .codebase),
            ]),
        LatticePreset(
            id: "minimal-context", name: "Minimal Context", glyph: "minus.circle",
            summary: "Just the prompt — no repository context injected.",
            cells: []),
    ]

    public static func preset(id: String) -> LatticePreset? {
        all.first { $0.id == id }
    }
}

// MARK: - Suggestions (deterministic rules — no fake classifier)

/// Deterministic prompt-analysis suggestions. Suggested cells render
/// differently from selected ones and are only activated by an explicit
/// "Apply Suggestions" action. Suggestions always respect availability.
public enum LatticeSuggestions {

    public struct Result: Sendable, Equatable {
        public var cells: [LatticeCellID]
        public var ruleName: String
    }

    public static func analyze(_ prompt: String) -> Result? {
        let p = prompt.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { p.contains($0) } }

        if has(["implement", "build", "create", "refactor", "add"]) {
            return Result(cells: [
                .init(.planner, .codebase), .init(.builder, .codebase),
                .init(.builder, .git), .init(.reviewer, .codebase),
                .init(.tester, .tests),
            ], ruleName: "Build-oriented task")
        }
        if has(["fix", "bug", "crash", "debug", "broken", "fails"]) {
            return Result(cells: [
                .init(.planner, .codebase), .init(.builder, .codebase),
                .init(.builder, .terminal), .init(.tester, .tests),
            ], ruleName: "Debug-oriented task")
        }
        if has(["review", "audit", "inspect"]) {
            return Result(cells: [
                .init(.reviewer, .openFiles), .init(.reviewer, .codebase),
                .init(.reviewer, .git),
            ], ruleName: "Review-oriented task")
        }
        if has(["research", "compare", "investigate", "how does", "explain"]) {
            return Result(cells: [
                .init(.researcher, .codebase), .init(.researcher, .documentation),
                .init(.planner, .codebase),
            ], ruleName: "Research-oriented task")
        }
        return nil
    }

    /// Filters suggestions to currently-available layers; cells already
    /// selected are dropped (nothing to apply).
    public static func applicable(
        _ result: Result,
        configuration: LatticeConfiguration,
        availability: (ContextLayer) -> CellAvailability
    ) -> [LatticeCellID] {
        result.cells.filter { cellID in
            !configuration.isSelected(cellID) && availability(cellID.context) == .available
        }
    }
}

// MARK: - Token budget

public struct LatticeTokenProjection: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var contextTokens: Int
    public var reservedOutputTokens: Int
    public var totalProjected: Int
    public var contextWindow: Int?
    public var usableWindow: Int?
    public var remaining: Int?
    /// 0…1+ of usableWindow. nil when no window is known (em-dash in UI).
    public var utilization: Double?

    public var fits: Bool {
        guard let usable = usableWindow else { return true }
        return totalProjected <= usable
    }
    public var nearLimit: Bool {
        guard let utilization else { return false }
        return utilization >= 0.85 && utilization <= 1.0
    }
}

// MARK: - Validation

public struct LatticeValidation: Sendable, Equatable {
    public var canRun: Bool
    /// Every blocking problem, in priority order — always surfaced in UI.
    public var blockers: [String]

    public init(canRun: Bool, blockers: [String]) {
        self.canRun = canRun
        self.blockers = blockers
    }

    public var primaryBlocker: String? { blockers.first }
}

public enum LatticeValidator {

    /// Single source of truth for run eligibility. Every condition in the
    /// spec maps to one check; the first failing check is the reason shown
    /// beside the disabled Run button.
    public static func validate(
        prompt: String,
        configuration: LatticeConfiguration,
        modelReady: Bool,
        modelLoading: Bool,
        hasWorkspace: Bool,
        projection: LatticeTokenProjection,
        runActive: Bool
    ) -> LatticeValidation {
        var blockers: [String] = []

        if runActive {
            blockers.append("A run is already in progress — stop it first.")
        }
        if modelLoading {
            blockers.append("The model is still loading.")
        } else if !modelReady {
            blockers.append("Choose a model before running.")
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockers.append("Describe the task first.")
        }
        if !hasWorkspace {
            blockers.append("Open a workspace — roles need a repository to work in.")
        }
        // "Minimal Context" (empty selection via preset) is a valid explicit
        // choice; an empty lattice with no preset applied is treated as
        // unconfigured so the user gets guidance instead of a bare run.
        if configuration.cells.isEmpty && configuration.presetID == nil {
            blockers.append("Apply a preset or select at least one role/context cell.")
        }
        if let usable = projection.usableWindow, projection.totalProjected > usable {
            blockers.append(
                "This configuration is estimated at \(projection.totalProjected.formatted()) tokens, " +
                "exceeding the model's \(usable.formatted())-token usable limit. Remove contexts or lower weights.")
        }

        return LatticeValidation(canRun: blockers.isEmpty, blockers: blockers)
    }
}

// MARK: - Run snapshot (immutable execution record)

/// Immutable record of a committed run. Created once at commit time; the
/// editable draft keeps evolving separately afterwards.
public struct LatticeRunSnapshot: Codable, Sendable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let prompt: String
    public let modelID: String
    public let modelDisplayName: String
    public let workspacePath: String
    public let configuration: LatticeConfiguration
    /// Execution plan: roles in order with their granted contexts — the
    /// manifest the agent runtime receives. Contains ONLY granted cells.
    public let plan: [StagePlan]
    public let projection: LatticeTokenProjection

    public struct StagePlan: Codable, Sendable, Equatable {
        public let role: LatticeRole
        public let contexts: [ContextLayer]
        public let weights: [Double]
    }

    public init(id: UUID = UUID(), createdAt: Date = Date(), prompt: String,
                modelID: String, modelDisplayName: String, workspacePath: String,
                configuration: LatticeConfiguration, plan: [StagePlan],
                projection: LatticeTokenProjection) {
        self.id = id; self.createdAt = createdAt; self.prompt = prompt
        self.modelID = modelID; self.modelDisplayName = modelDisplayName
        self.workspacePath = workspacePath
        self.configuration = configuration; self.plan = plan; self.projection = projection
    }

    /// Builds the manifest from a configuration — only cells present in the
    /// configuration appear; ordering is deterministic.
    public static func buildPlan(_ configuration: LatticeConfiguration) -> [StagePlan] {
        configuration.activeRoles.map { role in
            let contexts = configuration.grantedContexts(for: role)
            let weights = contexts.map { context in
                configuration.selection(for: LatticeCellID(role, context))?.weight ?? 1.0
            }
            return StagePlan(role: role, contexts: contexts, weights: weights)
        }
    }
}

// MARK: - Execution phases

public enum LatticePhase: String, Sendable, Equatable {
    case idle, editing, ready, preflighting, running, awaitingApproval
    case cancelling, completed, failed

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .editing: "Editing"
        case .ready: "Ready"
        case .preflighting: "Preflight"
        case .running: "Running"
        case .awaitingApproval: "Needs approval"
        case .cancelling: "Cancelling"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    public var glyph: String {
        switch self {
        case .idle: "circle"
        case .editing: "pencil"
        case .ready: "checkmark.circle"
        case .preflighting: "airplane.departure"
        case .running: "play.fill"
        case .awaitingApproval: "hand.raised"
        case .cancelling: "pause.circle"
        case .completed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

/// Live stage status for the Plan view during execution.
public enum LatticeExecutionStage: String, Sendable, Equatable {
    case pending, active, completed, failed, skipped

    public var glyph: String {
        switch self {
        case .pending: "circle.dotted"
        case .active: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }
}

// MARK: - Workspace views

public enum LatticeWorkspaceView: String, Codable, Sendable, CaseIterable, Identifiable {
    case lattice, plan, activity

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .lattice: "Lattice"
        case .plan: "Plan"
        case .activity: "Activity"
        }
    }
}

// MARK: - Manifest → prompt composition (bridge to the existing runtime)

/// Converts a validated configuration into the structured intent text the
/// existing agent loop receives (same seam the old preamble used). Every
/// role block lists ONLY its granted contexts; capabilities like Terminal
/// are phrased as permissions, not injected content.
public enum LatticeManifestBuilder {

    public static func build(
        configuration: LatticeConfiguration,
        resolvedContexts: (ContextLayer) -> String,
        draft: String
    ) -> String? {
        guard !configuration.cells.isEmpty else { return nil }
        var lines: [String] = ["Intent Lattice configuration for this task:"]

        for role in configuration.activeRoles {
            let contexts = configuration.grantedContexts(for: role)
            let weights = contexts.map { c in
                configuration.selection(for: LatticeCellID(role, c))?.weight ?? 1.0
            }
            var block = "- \(role.label): \(role.instruction)"
            if role == .orchestrator {
                block += " (coordination only — no additional capabilities granted)"
            }
            lines.append(block)
            for (context, weight) in zip(contexts, weights) {
                let weightText = weight >= 0.99 ? "" : String(format: " (weight %.0f%%)", weight * 100)
                let content = resolvedContexts(context)
                if content.isEmpty {
                    lines.append("    · \(context.label)\(weightText)")
                } else {
                    lines.append("    · \(context.label)\(weightText):")
                    lines.append(indent(content, by: "      "))
                }
            }
            let notes = contexts.compactMap { context in
                configuration.selection(for: LatticeCellID(role, context))?.note
            }.filter { !$0.isEmpty }
            for note in notes {
                lines.append("    · Note: \(note)")
            }
        }
        lines.append("")
        lines.append(draft)
        return lines.joined(separator: "\n")
    }

    private static func indent(_ text: String, by prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}
