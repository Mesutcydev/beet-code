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

    init(
        autoApproveEdits: Bool = false,
        autoApproveCommands: Bool = false,
        commandPolicy: CommandPolicy = CommandPolicy(),
        workspace: Workspace = Workspace(root: URL(fileURLWithPath: "/"))
    ) {
        self.autoApproveEdits = autoApproveEdits
        self.autoApproveCommands = autoApproveCommands
        self.commandPolicy = commandPolicy
        self.workspace = workspace
    }

    func decision(for call: ParsedToolCall, risk: ToolRisk?) -> Decision {
        switch risk {
        case .read:
            return .auto
        case .none:
            return .needsApproval
        case .write:
            return autoApproveEdits ? .auto : .needsApproval
        case .execute:
            guard let command = call.string("command") else { return .needsApproval }
            let policy = commandPolicy.evaluate(command, workspace: workspace)
            // Auto-approval is a *safe-command policy*, never a blanket shell
            // bypass: even a policy-safe command asks by default, and enabling
            // auto-approve only admits the exact validated forms.
            return autoApproveCommands && policy.safeForAutoApproval ? .auto : .needsApproval
        }
    }
}
