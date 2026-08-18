import Foundation

/// Live, mid-run approval overrides for the PermissionGate.
///
/// When the user taps "Always approve" on an approval card, the decision
/// must take effect IMMEDIATELY — the running agent loop already holds a
/// `PermissionGate` value, so a settings change alone would only apply to
/// the next run. This lock-guarded reference is created per run, handed to
/// both the gate (read side) and the controller (write side), and consulted
/// before the static gate flags.
///
/// Safety posture is unchanged: overrides only ever WIDEN approval within
/// the two explicit categories (file edits / policy-safe commands). Reads,
/// plan approval, and the command allowlist policy are untouched — a
/// blanket shell bypass remains impossible because the gate still requires
/// `policy.safeForAutoApproval` for commands.
final class ApprovalOverrides: @unchecked Sendable {

    private let lock = NSLock()
    private var editsAllowed = false
    private var commandsAllowed = false

    var allowsEdits: Bool {
        lock.lock(); defer { lock.unlock() }
        return editsAllowed
    }

    var allowsCommands: Bool {
        lock.lock(); defer { lock.unlock() }
        return commandsAllowed
    }

    func allowEdits() {
        lock.lock(); editsAllowed = true; lock.unlock()
    }

    func allowCommands() {
        lock.lock(); commandsAllowed = true; lock.unlock()
    }
}
