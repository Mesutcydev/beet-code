import Foundation

/// Swift port of the Lattice engine stack (composition + budgeting + dynamic
/// estimation). Pure and Foundation-only so it lives in Core and is unit-
/// testable; the SwiftUI composer bridges into it. Mirrors
/// lattice-composer/src/{composeContext,tokenBudget,tokenEstimation}.ts.

public enum LatticeModelFamily: String, Sendable, Codable {
    case gpt, claude, llama, gemini, generic
}

public struct LatticeEngineCell: Sendable, Equatable {
    public var id: String
    public var rowId: String
    public var colId: String
    public var active: Bool
    public var weight: Double        // 0..1
    public var locked: Bool
    public var promptFragment: String
    public var status: String        // idle/active/running/success/warning/error/muted

    public init(id: String, rowId: String, colId: String, active: Bool,
                weight: Double, locked: Bool = false, promptFragment: String, status: String = "idle") {
        self.id = id; self.rowId = rowId; self.colId = colId; self.active = active
        self.weight = weight; self.locked = locked; self.promptFragment = promptFragment; self.status = status
    }
}

public struct LatticeEngineState: Sendable {
    public var cells: [LatticeEngineCell]
    public var freeText: String
    public init(cells: [LatticeEngineCell], freeText: String = "") {
        self.cells = cells; self.freeText = freeText
    }
}

public struct ResolvedContext: Sendable, Equatable {
    public var source: String
    public var content: String
    public var tokenEstimate: Int
    public init(source: String, content: String, tokenEstimate: Int) {
        self.source = source; self.content = content; self.tokenEstimate = tokenEstimate
    }
}

public struct ComposedBlock: Sendable, Equatable {
    public var role: String
    public var content: String
    public var weight: Double
    public var cellId: String
    public var priority: Int
}

public struct CompositionResult: Sendable, Equatable {
    public var systemBlocks: [ComposedBlock]
    public var systemContent: String
    public var totalEstimatedTokens: Int
    public var activeCellCount: Int
    public var sortedIds: [String]
    public var discardedIds: [String]
}

public struct TokenBudgetConfig: Sendable {
    public var hardLimit: Int
    public var softLimit: Int
    public var responseReserve: Int
    public var protectLocked: Bool
    public init(hardLimit: Int = 32_000, softLimit: Int = 24_000,
                responseReserve: Int = 4_000, protectLocked: Bool = true) {
        self.hardLimit = hardLimit; self.softLimit = softLimit
        self.responseReserve = responseReserve; self.protectLocked = protectLocked
    }
}

public struct BudgetStatus: Sendable, Equatable {
    public var used: Int
    public var budget: Int
    public var remaining: Int
    public var softExceeded: Bool
    public var hardExceeded: Bool
    public var utilization: Double
    public var warnings: [String]
    public var prunedCellIds: [String]
}

public enum LatticeEngine {
    public static let rowPriority: [String: Int] = [
        "plan": 10, "reason": 15, "ask": 20, "implement": 30, "verify": 40, "background": 50,
    ]
    public static let defaultPriority = 100

    // MARK: Estimation

    public static func estimateTokens(_ text: String, model: LatticeModelFamily = .generic) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        // Honest heuristic: ≈ chars/4. Displayed with "≈" in the UI. When an
        // engine exposes a real tokenizer, callers should use that instead.
        _ = model
        return max(1, Int((Double(trimmed.count) / 4.0).rounded(.up)))
    }

    // MARK: Composition

    public static func compose(
        _ state: LatticeEngineState,
        resolve: (String) -> [ResolvedContext] = { _ in [] }
    ) -> CompositionResult {
        let active = state.cells.filter { $0.active && $0.weight > 0 && $0.status != "muted" }
        let sorted = active.sorted { a, b in
            let pa = rowPriority[a.rowId] ?? defaultPriority
            let pb = rowPriority[b.rowId] ?? defaultPriority
            if pa != pb { return pa < pb }
            if a.weight != b.weight { return a.weight > b.weight }
            return a.id < b.id
        }
        var blocks: [ComposedBlock] = []
        var total = 0
        for cell in sorted {
            let sources = resolve(cell.colId)
            let contextText = sources.map { "[\($0.source)]\n\($0.content)" }.joined(separator: "\n\n")
            let full = contextText.isEmpty
                ? cell.promptFragment
                : cell.promptFragment + "\n\n--- Context ---\n" + contextText
            let blockTokens = estimateTokens(cell.promptFragment) + sources.reduce(0) { $0 + $1.tokenEstimate }
            blocks.append(ComposedBlock(
                role: cell.rowId, content: full, weight: cell.weight, cellId: cell.id,
                priority: rowPriority[cell.rowId] ?? defaultPriority))
            total += blockTokens
        }
        let systemContent = blocks.map { b in
            "### \(b.role.uppercased()) · \(b.cellId.split(separator: ":").last.map(String.init) ?? "")\n\(b.content)"
        }.joined(separator: "\n\n")
        let discarded = state.cells
            .filter { !($0.active && $0.weight > 0 && $0.status != "muted") }
            .map(\.id)
        return CompositionResult(
            systemBlocks: blocks, systemContent: systemContent,
            totalEstimatedTokens: total + estimateTokens(state.freeText),
            activeCellCount: sorted.count, sortedIds: sorted.map(\.id), discardedIds: discarded)
    }

    // MARK: Budgeting

    public static func usage(_ state: LatticeEngineState,
                             resolve: (String) -> [ResolvedContext] = { _ in [] }) -> Int {
        compose(state, resolve: resolve).totalEstimatedTokens
    }

    public static func budgetStatus(
        _ state: LatticeEngineState,
        config: TokenBudgetConfig = TokenBudgetConfig(),
        resolve: (String) -> [ResolvedContext] = { _ in [] }
    ) -> BudgetStatus {
        let used = usage(state, resolve: resolve)
        var warnings: [String] = []
        if used > config.softLimit { warnings.append("Soft limit exceeded (\(used) / \(config.softLimit))") }
        if used > config.hardLimit - config.responseReserve { warnings.append("Approaching hard limit - headroom low") }
        if used > config.hardLimit { warnings.append("Hard limit exceeded - pruning required") }
        return BudgetStatus(
            used: used, budget: config.hardLimit, remaining: max(0, config.hardLimit - used),
            softExceeded: used > config.softLimit, hardExceeded: used > config.hardLimit,
            utilization: min(1, Double(used) / Double(config.hardLimit)),
            warnings: warnings, prunedCellIds: [])
    }

    public static func pruneToBudget(
        _ state: LatticeEngineState,
        config: TokenBudgetConfig = TokenBudgetConfig(),
        resolve: (String) -> [ResolvedContext] = { _ in [] }
    ) -> (state: LatticeEngineState, pruned: [String]) {
        var current = state
        var pruned: [String] = []
        guard usage(current, resolve: resolve) > config.hardLimit else { return (current, pruned) }
        let candidates = current.cells
            .filter { $0.active && $0.weight > 0 && $0.status != "muted" }
            .filter { !(config.protectLocked && $0.locked) }
            .sorted { a, b in
                let pa = rowPriority[a.rowId] ?? defaultPriority
                let pb = rowPriority[b.rowId] ?? defaultPriority
                if pa != pb { return pa > pb }
                if a.weight != b.weight { return a.weight < b.weight }
                return a.id < b.id
            }
        for cell in candidates {
            if usage(current, resolve: resolve) <= config.hardLimit { break }
            if let i = current.cells.firstIndex(where: { $0.id == cell.id }) {
                current.cells[i].active = false
                current.cells[i].status = "muted"
                pruned.append(cell.id)
            }
        }
        return (current, pruned)
    }

    public static func budgetAwareCompose(
        _ state: LatticeEngineState,
        config: TokenBudgetConfig = TokenBudgetConfig(),
        resolve: (String) -> [ResolvedContext] = { _ in [] }
    ) -> (composition: CompositionResult, budget: BudgetStatus, pruned: [String]) {
        var working = state
        var pruned: [String] = []
        if budgetStatus(state, config: config, resolve: resolve).hardExceeded {
            let r = pruneToBudget(state, config: config, resolve: resolve)
            working = r.state; pruned = r.pruned
        }
        let composition = compose(working, resolve: resolve)
        var status = budgetStatus(working, config: config, resolve: resolve)
        status.prunedCellIds = pruned
        if !pruned.isEmpty { status.warnings.append("Pruned \(pruned.count) low-priority cell(s) to fit budget") }
        return (composition, status, pruned)
    }
}
