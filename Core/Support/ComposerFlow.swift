import Foundation

/// Configurable animated-composer flow presets (Copilot-style input box).
/// Lives in Core (not App) because SettingsStore persists the selection and
/// the CLI target must compile without the UI layer; the SwiftUI color
/// palette for each flow is an App-layer extension in ComposerStyle.swift.
enum ComposerFlow: String, CaseIterable, Identifiable, Codable, Sendable {
    case aurora
    case ember
    case ocean
    case graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aurora: "Aurora"
        case .ember: "Ember"
        case .ocean: "Ocean"
        case .graphite: "Graphite"
        }
    }

    /// Seconds per full gradient cycle; slower = calmer.
    var cycleSeconds: Double {
        switch self {
        case .aurora: 6
        case .ember: 4
        case .ocean: 7
        case .graphite: 9
        }
    }
}
