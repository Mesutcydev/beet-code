import Foundation

// MARK: - Roles

/// Agent roles in the Intent Lattice. The Orchestrator is a global
/// coordination role — it never silently gains contexts of its own.
public enum LatticeRole: String, CaseIterable, Codable, Sendable, Identifiable {
    case orchestrator, researcher, planner, builder, reviewer, tester

    public var id: String { rawValue }

    /// Deterministic execution order. Only configured roles run.
    /// The Orchestrator coordinates globally, not as a sequential worker.
    public var executionOrder: Int {
        switch self {
        case .orchestrator: 0   // coordination, runs alongside
        case .researcher: 1
        case .planner: 2
        case .builder: 3
        case .reviewer: 4
        case .tester: 5
        }
    }

    public var label: String {
        switch self {
        case .orchestrator: "Orchestrator"
        case .researcher: "Researcher"
        case .planner: "Planner"
        case .builder: "Builder"
        case .reviewer: "Reviewer"
        case .tester: "Tester"
        }
    }

    public var glyph: String {
        switch self {
        case .orchestrator: "dial.low.fill"
        case .researcher: "magnifyingglass"
        case .planner: "list.bullet.clipboard"
        case .builder: "hammer"
        case .reviewer: "checkmark.seal"
        case .tester: "testtube.2"
        }
    }

    public var summary: String {
        switch self {
        case .orchestrator: "Coordinates the run; never adds contexts the user did not grant."
        case .researcher: "Reads relevant code and context before proposing changes."
        case .planner: "Proposes a plan and the files to touch before editing."
        case .builder: "Implements the change file by file with minimal edits."
        case .reviewer: "Checks correctness, edge cases, and style by severity."
        case .tester: "Runs builds and tests; reports exact commands and output."
        }
    }

    /// Exact instruction injected for this role (~20 tokens).
    public var instruction: String {
        switch self {
        case .orchestrator:
            "Coordinate the run: sequence the configured roles and summarize progress; use only the granted contexts."
        case .researcher:
            "Read the relevant code and project context before proposing or making changes; never guess what's in a file."
        case .planner:
            "Propose a concise plan with the files to change before editing; keep it under 10 bullets."
        case .builder:
            "Implement the change file by file; keep each edit minimal and say what changed and why."
        case .reviewer:
            "Check the change for correctness, edge cases, and style; report concerns by severity."
        case .tester:
            "Run the relevant builds/tests after editing; if anything fails, report the exact command and the key output."
        }
    }
}

// MARK: - Context layers

/// Contexts and capabilities a role may be granted. A selected cell means:
/// "Allow this role to use this context or capability during execution."
public enum ContextLayer: String, CaseIterable, Codable, Sendable, Identifiable {
    case openFiles, codebase, documentation, terminal, git, memory, tools, tests

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openFiles: "Open Files"
        case .codebase: "Codebase"
        case .documentation: "Documentation"
        case .terminal: "Terminal"
        case .git: "Git"
        case .memory: "Memory"
        case .tools: "Tools"
        case .tests: "Tests"
        }
    }

    public var glyph: String {
        switch self {
        case .openFiles: "doc.on.doc"
        case .codebase: "folder"
        case .documentation: "book"
        case .terminal: "terminal"
        case .git: "arrow.triangle.branch"
        case .memory: "brain"
        case .tools: "wrench.and.screwdriver"
        case .tests: "checklist"
        }
    }

    /// Inspector copy explaining exactly what this grants.
    public var description: String {
        switch self {
        case .openFiles:
            "Currently attached/selected files. Granting this adds their content references to the role."
        case .codebase:
            "The indexed workspace. The role receives repository context and may search files."
        case .documentation:
            "Project documentation (docs/, README, AGENTS.md) injected for the role."
        case .terminal:
            "Command execution. Requests still pass the normal approval policy."
        case .git:
            "Repository status, current diff, branch, and history context for the role."
        case .memory:
            "Conversation/project memory (facts and session summaries) in context."
        case .tools:
            "Registered tools — built-in coding tools plus any connected MCP servers."
        case .tests:
            "Discovered test targets, test files, and previous results."
        }
    }
}

// MARK: - Cell identity

public struct LatticeCellID: Hashable, Codable, Sendable {
    public let role: LatticeRole
    public let context: ContextLayer

    public init(_ role: LatticeRole, _ context: ContextLayer) {
        self.role = role
        self.context = context
    }

    public var key: String { "\(role.rawValue):\(context.rawValue)" }
}

// MARK: - Selection

public enum SelectionSource: String, Codable, Sendable {
    case manual, suggested, preset
}

/// One selected cell. Weight 0.0–1.0 scales how strongly the context is
/// emphasized in the role's prompt block.
public struct LatticeCellSelection: Codable, Sendable, Equatable {
    public var id: LatticeCellID
    public var weight: Double
    public var source: SelectionSource
    /// Optional per-cell instruction override from the inspector.
    public var note: String?

    public init(id: LatticeCellID, weight: Double = 1.0,
                source: SelectionSource = .manual, note: String? = nil) {
        self.id = id
        self.weight = min(max(weight, 0), 1)
        self.source = source
        self.note = note
    }
}

// MARK: - Configuration

public struct LatticeConfiguration: Codable, Sendable, Equatable {
    public var cells: [String: LatticeCellSelection]
    public var presetID: String?

    public init(cells: [String: LatticeCellSelection] = [:], presetID: String? = nil) {
        self.cells = cells
        self.presetID = presetID
    }

    public var selections: [LatticeCellSelection] {
        cells.values.sorted { $0.id.key < $1.id.key }
    }

    public func isSelected(_ id: LatticeCellID) -> Bool {
        cells[id.key] != nil
    }

    public func selection(for id: LatticeCellID) -> LatticeCellSelection? {
        cells[id.key]
    }

    /// Roles with at least one granted context, in execution order.
    public var activeRoles: [LatticeRole] {
        let roles = Set(cells.values.map(\.id.role))
        return LatticeRole.allCases
            .filter { roles.contains($0) }
            .sorted { $0.executionOrder < $1.executionOrder }
    }

    /// Contexts granted to a role, in canonical layer order.
    public func grantedContexts(for role: LatticeRole) -> [ContextLayer] {
        let contexts = Set(cells.values.filter { $0.id.role == role }.map(\.id.context))
        return ContextLayer.allCases.filter { contexts.contains($0) }
    }
}

// MARK: - Availability (real application state only)

/// Everything availability decisions derive from. Populated from live app
/// state — never mocked in production paths.
public struct LatticeAvailabilityInput: Sendable, Equatable {
    public var hasWorkspace: Bool
    public var attachedFileCount: Int
    public var isGitRepo: Bool
    public var hasDocumentation: Bool
    public var hasTestTargets: Bool
    public var builtInToolCount: Int
    public var mcpServerCount: Int
    public var memoryEnabled: Bool

    public init(
        hasWorkspace: Bool, attachedFileCount: Int, isGitRepo: Bool,
        hasDocumentation: Bool, hasTestTargets: Bool, builtInToolCount: Int,
        mcpServerCount: Int, memoryEnabled: Bool
    ) {
        self.hasWorkspace = hasWorkspace
        self.attachedFileCount = attachedFileCount
        self.isGitRepo = isGitRepo
        self.hasDocumentation = hasDocumentation
        self.hasTestTargets = hasTestTargets
        self.builtInToolCount = builtInToolCount
        self.mcpServerCount = mcpServerCount
        self.memoryEnabled = memoryEnabled
    }
}

public enum CellAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String, recovery: String?)
}

/// Maps real workspace/app state to per-layer availability with exact
/// reasons and recovery actions.
public enum ContextAvailability {

    public static func availability(for layer: ContextLayer,
                                    input: LatticeAvailabilityInput) -> CellAvailability {
        switch layer {
        case .openFiles:
            if input.attachedFileCount > 0 { return .available }
            return .unavailable(
                reason: "No files are attached or selected.",
                recovery: "Attach a file with the paperclip button (⌘V pastes a screenshot).")
        case .codebase, .terminal:
            guard input.hasWorkspace else {
                return .unavailable(reason: "No workspace is open.", recovery: "Choose Workspace")
            }
            return .available
        case .documentation:
            guard input.hasWorkspace else {
                return .unavailable(reason: "No workspace is open.", recovery: "Choose Workspace")
            }
            if input.hasDocumentation { return .available }
            return .unavailable(
                reason: "No docs/, README, or AGENTS.md found in this workspace.",
                recovery: nil)
        case .git:
            guard input.hasWorkspace else {
                return .unavailable(reason: "No workspace is open.", recovery: "Choose Workspace")
            }
            if input.isGitRepo { return .available }
            return .unavailable(
                reason: "The selected folder is not a git repository.",
                recovery: "Initialize Repository")
        case .memory:
            if input.memoryEnabled { return .available }
            return .unavailable(
                reason: "Project memory is off.",
                recovery: "Enable Project Memory in Settings → Agent")
        case .tools:
            let total = input.builtInToolCount + input.mcpServerCount
            if total > 0 { return .available }
            return .unavailable(reason: "No tools are registered.", recovery: "Connect Tools")
        case .tests:
            guard input.hasWorkspace else {
                return .unavailable(reason: "No workspace is open.", recovery: "Choose Workspace")
            }
            if input.hasTestTargets { return .available }
            return .unavailable(
                reason: "No test targets discovered in this workspace.",
                recovery: "Discover Tests")
        }
    }
}
