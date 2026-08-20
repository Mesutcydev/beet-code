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
        case denied(String)
    }

    var autoApproveEdits: Bool
    var autoApproveCommands: Bool
    var commandPolicy: CommandPolicy
    var workspace: Workspace
    /// Live mid-run overrides ("Always approve" tapped on an approval card).
    /// Consulted before the static flags; nil = no overrides in play.
    var overrides: ApprovalOverrides?
    /// Rules imported from OpenCode's `permission` / `permissions` config.
    /// An empty set leaves Beet Code's native approval policy unchanged.
    var openCodePermissions: OpenCodeCompatibility.OpenCodePermissionSet

    init(
        autoApproveEdits: Bool = false,
        autoApproveCommands: Bool = false,
        commandPolicy: CommandPolicy = CommandPolicy(),
        workspace: Workspace = Workspace(root: URL(fileURLWithPath: "/")),
        overrides: ApprovalOverrides? = nil,
        openCodePermissions: OpenCodeCompatibility.OpenCodePermissionSet = .empty
    ) {
        self.autoApproveEdits = autoApproveEdits
        self.autoApproveCommands = autoApproveCommands
        self.commandPolicy = commandPolicy
        self.workspace = workspace
        self.overrides = overrides
        self.openCodePermissions = openCodePermissions
    }

    func decision(for call: ParsedToolCall, risk: ToolRisk?) -> Decision {
        let compatibility = compatibilityDecision(for: call, risk: risk)
        if case .denied = compatibility { return compatibility }
        if case .needsApproval = compatibility { return compatibility }

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

    private func compatibilityDecision(for call: ParsedToolCall, risk: ToolRisk?) -> Decision {
        let (action, resource) = openCodeTarget(for: call, risk: risk)
        guard let effect = openCodePermissions.effect(action: action, resource: resource) else {
            return .auto
        }
        switch effect {
        case .deny:
            return .denied("OpenCode permission denied: \(action) on \(resource).")
        case .ask:
            return .needsApproval
        case .allow:
            // OpenCode's allow is authoritative for reads and edits. Shell
            // commands still pass Beet Code's safe-command policy below; an
            // imported config must not silently turn a dangerous command into
            // an unreviewed process launch.
            return .auto
        }
    }

    private func openCodeTarget(for call: ParsedToolCall, risk: ToolRisk?) -> (String, String) {
        let lower = call.name.lowercased()
        let resource = call.string("path")
            ?? call.string("command")
            ?? call.string("server")
            ?? call.string("url")
            ?? "*"
        if lower == "run_command" || lower == "shell" || lower == "bash" {
            return ("shell", call.string("command") ?? "*")
        }
        if lower == "task" {
            return ("task", call.string("agent") ?? "*")
        }
        if lower.hasPrefix("mcp__") {
            return (call.name, resource)
        }
        switch risk {
        case .read: return ("read", resource)
        case .write: return ("edit", resource)
        case .execute: return ("shell", resource)
        case .none: return (call.name, resource)
        }
    }
}
