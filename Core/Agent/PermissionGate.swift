import Foundation

/// Decides whether a tool call may run without asking. Explicit and dumb on
/// purpose — the loop consults it, the executor never second-guesses it, the
/// UI cannot bypass it.
///
/// Reads are always automatic. Writes need approval unless auto-approve is on.
/// Commands need approval unless auto-approved or allowlist-prefixed.
struct PermissionGate: Sendable {

    enum Decision: Sendable, Equatable {
        case auto
        case needsApproval
    }

    var autoApproveEdits: Bool
    var autoApproveCommands: Bool
    var commandPolicy: CommandPolicy
    var workspace: Workspace
    /// Live mid-run overrides ("Always approve" tapped on an approval card).
    /// Consulted before the static flags; nil = no overrides in play.
    var overrides: ApprovalOverrides?

    init(
        autoApproveEdits: Bool = false,
        autoApproveCommands: Bool = false,
        commandPolicy: CommandPolicy = CommandPolicy(),
        workspace: Workspace = Workspace(root: URL(fileURLWithPath: "/")),
        overrides: ApprovalOverrides? = nil
    ) {
        self.autoApproveEdits = autoApproveEdits
        self.autoApproveCommands = autoApproveCommands
        self.commandPolicy = commandPolicy
        self.workspace = workspace
        self.overrides = overrides
    }

    func decision(for call: ParsedToolCall, risk: ToolRisk?) -> Decision {
        switch risk {
        case .read:
            return .auto
        case .none:
            return .needsApproval
        case .write:
            let liveEdits = overrides?.allowsEdits ?? false
            return (autoApproveEdits || liveEdits) ? .auto : .needsApproval
        case .execute:
            guard let command = call.string("command") else { return .needsApproval }
            let policy = commandPolicy.evaluate(command, workspace: workspace)
            // Auto-approval is a *safe-command policy*, never a blanket shell
            // bypass: even a policy-safe command asks by default, and enabling
            // auto-approve only admits the exact validated forms. Live
            // overrides follow the exact same policy gate.
            let liveCommands = overrides?.allowsCommands ?? false
            return (autoApproveCommands || liveCommands) && policy.safeForAutoApproval
                ? .auto : .needsApproval
        }
    }
}
