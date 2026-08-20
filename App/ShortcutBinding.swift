import SwiftUI

/// User-editable macOS shortcut syntax. The stored form stays human-readable
/// (`cmd+shift+p`) while the app uses native SwiftUI key equivalents.
struct ShortcutBinding: Equatable {
    let key: String
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    init(rawValue: String) {
        let parts = rawValue
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: true)
            .map(String.init)
        let keyPart = parts.last.flatMap(Self.normalizedKey) ?? "return"
        key = keyPart
        command = parts.dropLast().contains { $0 == "cmd" || $0 == "command" }
        shift = parts.dropLast().contains { $0 == "shift" }
        option = parts.dropLast().contains { $0 == "option" || $0 == "alt" }
        control = parts.dropLast().contains { $0 == "control" || $0 == "ctrl" }
    }

    var canonicalValue: String {
        var parts: [String] = []
        if command { parts.append("cmd") }
        if shift { parts.append("shift") }
        if option { parts.append("option") }
        if control { parts.append("control") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    var displayValue: String {
        var value = ""
        if command { value += "⌘" }
        if shift { value += "⇧" }
        if option { value += "⌥" }
        if control { value += "⌃" }
        switch key {
        case "return", "enter": value += "↩"
        case "escape", "esc": value += "⎋"
        case "space": value += "Space"
        case "tab": value += "⇥"
        case "delete", "backspace": value += "⌫"
        default: value += key.uppercased()
        }
        return value
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return", "enter": .return
        case "escape", "esc": .escape
        case "space": .space
        case "tab": .tab
        case "delete", "backspace": .delete
        case "up": .upArrow
        case "down": .downArrow
        case "left": .leftArrow
        case "right": .rightArrow
        default: KeyEquivalent(key.first ?? Character(" "))
        }
    }

    var eventModifiers: EventModifiers {
        var value: EventModifiers = []
        if command { value.insert(.command) }
        if shift { value.insert(.shift) }
        if option { value.insert(.option) }
        if control { value.insert(.control) }
        return value
    }

    func matches(_ press: KeyPress) -> Bool {
        press.key == keyEquivalent && press.modifiers == eventModifiers
    }

    private static func normalizedKey(_ value: String) -> String? {
        let aliases = [
            "enter": "return",
            "esc": "escape",
            "backspace": "delete",
            "uparrow": "up",
            "downarrow": "down",
            "leftarrow": "left",
            "rightarrow": "right"
        ]
        if let alias = aliases[value] { return alias }
        if ["return", "escape", "space", "tab", "delete", "up", "down", "left", "right"].contains(value) {
            return value
        }
        guard value.count == 1 else { return nil }
        return value
    }
}
