import AppKit

/// Small native passphrase prompt shared by task-bundle export and import.
/// The passphrase is held only in the prompt's local scope and is never
/// persisted in preferences, session records, diagnostics, or the Keychain.
@MainActor
enum TaskBundlePassphrasePrompt {

    static func ask(forExport: Bool) -> String? {
        while true {
            let alert = NSAlert()
            alert.messageText = forExport ? "Protect task bundle" : "Unlock task bundle"
            alert.informativeText = forExport
                ? "Choose a passphrase with at least 8 characters. You will need it to import this task on another Mac."
                : "Enter the passphrase used when this task bundle was exported."
            alert.alertStyle = .informational

            let passphrase = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
            passphrase.placeholderString = forExport ? "Passphrase" : "Task bundle passphrase"
            passphrase.setAccessibilityLabel(forExport ? "New bundle passphrase" : "Task bundle passphrase")

            var fields = [passphrase]
            if forExport {
                let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
                confirmation.placeholderString = "Confirm passphrase"
                confirmation.setAccessibilityLabel("Confirm bundle passphrase")
                fields.append(confirmation)
            }

            let stack = NSStackView(views: fields)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.frame = NSRect(
                x: 0,
                y: 0,
                width: 340,
                height: CGFloat(fields.count * 24 + max(fields.count - 1, 0) * 8))
            alert.accessoryView = stack
            alert.addButton(withTitle: forExport ? "Protect" : "Unlock")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let value = passphrase.stringValue

            if forExport {
                guard value.count >= TaskBundleCodec.minimumPassphraseLength else {
                    showValidationError("Use a passphrase with at least 8 characters.")
                    continue
                }
                guard fields.count == 2, fields[1].stringValue == value else {
                    showValidationError("The passphrases do not match.")
                    continue
                }
            }
            return value
        }
    }

    private static func showValidationError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Passphrase not accepted"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
