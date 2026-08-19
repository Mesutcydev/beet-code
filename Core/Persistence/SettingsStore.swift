import Foundation

/// App color appearance. `system` follows macOS; `light`/`dark` force it;
/// `beet` is the identity theme — a dark appearance whose neutrals are
/// tinted from Beet Red (Pantone 19-2030 TCX) instead of cool slate.
/// Light is the default. Kept Foundation-only (no SwiftUI) so the CLI target
/// can compile this file; the SwiftUI `ColorScheme` mapping lives in the app.
enum AppAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark
    case beet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .beet: "Beet"
        }
    }
}

/// Accent color palettes. Every entry ships a light+dark hex pair for both
/// the accent and its brighter variant; `Theme` resolves them at draw time.
/// `beetRed` is the identity default (Pantone 19-2030 TCX, #7A1F3D).
/// Foundation-only (no SwiftUI) so the CLI target can compile this file;
/// the SwiftUI swatch extension lives in App/Theme.swift.
enum AccentPalette: String, CaseIterable, Codable, Identifiable, Sendable {
    case beetRed
    case indigo
    case ocean
    case forest
    case amber
    case graphite

    var id: String { rawValue }

    struct Hexes: Sendable, Equatable {
        var accentLight: UInt32
        var accentDark: UInt32
        var brightLight: UInt32
        var brightDark: UInt32
    }

    var label: String {
        switch self {
        case .beetRed: "Beet Red"
        case .indigo: "Indigo"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .amber: "Amber"
        case .graphite: "Graphite"
        }
    }

    var hexes: Hexes {
        switch self {
        case .beetRed:
            // Pantone 19-2030 TCX — #7A1F3D; dark mode lifts the hue.
            Hexes(accentLight: 0x7A1F3D, accentDark: 0xD14775,
                  brightLight: 0x8A2647, brightDark: 0xE06C92)
        case .indigo:
            Hexes(accentLight: 0x6C5CE7, accentDark: 0x8B7BFF,
                  brightLight: 0x7C6CF7, brightDark: 0xA99BFF)
        case .ocean:
            Hexes(accentLight: 0x1E6FD9, accentDark: 0x5AA0FF,
                  brightLight: 0x2B7FFF, brightDark: 0x7AB4FF)
        case .forest:
            Hexes(accentLight: 0x1E7A52, accentDark: 0x35D6A0,
                  brightLight: 0x2A8F62, brightDark: 0x5CE0B4)
        case .amber:
            Hexes(accentLight: 0xB87400, accentDark: 0xF5B23D,
                  brightLight: 0xD08A10, brightDark: 0xFFC861)
        case .graphite:
            Hexes(accentLight: 0x4A5060, accentDark: 0x9AA1B2,
                  brightLight: 0x5B616E, brightDark: 0xB4BAC9)
        }
    }
}

/// User-facing settings. Defaults encode the safety posture: edits and shell
/// commands always ask, reads never do.
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    init() {
        // Register defaults so first read is well-defined.
        defaults.register(defaults: [
            DefaultsKeys.autoApproveEdits: false,
            DefaultsKeys.autoApproveCommands: false,
            DefaultsKeys.maxTurns: 40,
            DefaultsKeys.maxTokensPerTurn: 4096,
            DefaultsKeys.temperature: 0.6,
            DefaultsKeys.checkpointingEnabled: true,
            DefaultsKeys.verifyAfterEdits: false,
            DefaultsKeys.memoryMode: "off",
            DefaultsKeys.compressionLevel: "standard",
            DefaultsKeys.composerFlow: "aurora",
            DefaultsKeys.showReasoning: false,
            DefaultsKeys.planMode: false,
            DefaultsKeys.appearance: AppAppearance.light.rawValue,
            DefaultsKeys.accentPalette: AccentPalette.beetRed.rawValue,
            DefaultsKeys.composerBorderAnimation: true,
            DefaultsKeys.apiServerEnabled: false,
            DefaultsKeys.apiServerPort: 1234,
        ])
    }

    /// Color appearance. Defaults to light; `system` follows macOS.
    var appearance: AppAppearance {
        get {
            AppAppearance(
                rawValue: defaults.string(forKey: DefaultsKeys.appearance)
                    ?? AppAppearance.light.rawValue) ?? .light
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKeys.appearance)
            objectWillChange.send()
        }
    }

    /// Accent color palette. Defaults to Beet Red (the app identity).
    /// `Theme.applyPalette` is invoked from the app layer on change.
    var accentPalette: AccentPalette {
        get {
            AccentPalette(
                rawValue: defaults.string(forKey: DefaultsKeys.accentPalette)
                    ?? AccentPalette.beetRed.rawValue) ?? .beetRed
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKeys.accentPalette)
            objectWillChange.send()
        }
    }

    var autoApproveEdits: Bool {
        get { defaults.bool(forKey: DefaultsKeys.autoApproveEdits) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.autoApproveEdits)
            objectWillChange.send()
        }
    }

    var autoApproveCommands: Bool {
        get { defaults.bool(forKey: DefaultsKeys.autoApproveCommands) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.autoApproveCommands)
            objectWillChange.send()
        }
    }

    var maxTurns: Int {
        get { defaults.integer(forKey: DefaultsKeys.maxTurns) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.maxTurns)
            objectWillChange.send()
        }
    }

    var maxTokensPerTurn: Int {
        get { defaults.integer(forKey: DefaultsKeys.maxTokensPerTurn) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.maxTokensPerTurn)
            objectWillChange.send()
        }
    }

    var temperature: Double {
        get { defaults.double(forKey: DefaultsKeys.temperature) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.temperature)
            objectWillChange.send()
        }
    }

    var checkpointingEnabled: Bool {
        get { defaults.bool(forKey: DefaultsKeys.checkpointingEnabled) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.checkpointingEnabled)
            objectWillChange.send()
        }
    }

    var memoryMode: MemoryMode {
        get {
            MemoryMode(rawValue: defaults.string(forKey: DefaultsKeys.memoryMode) ?? "off") ?? .off
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKeys.memoryMode)
            objectWillChange.send()
        }
    }

    /// Show the model's chain-of-thought (think blocks) in the transcript.
    var showReasoning: Bool {
        get { defaults.bool(forKey: DefaultsKeys.showReasoning) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.showReasoning)
            objectWillChange.send()
        }
    }

    /// Plan mode: the agent presents a plan and waits for approval before
    /// any tool executes.
    var planMode: Bool {
        get { defaults.bool(forKey: DefaultsKeys.planMode) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.planMode)
            objectWillChange.send()
        }
    }

    /// Composer signature: the animated gradient underline. Off = static
    /// hairline (also friendlier for Reduce Motion sensibilities).
    var composerBorderAnimation: Bool {
        get { defaults.bool(forKey: DefaultsKeys.composerBorderAnimation) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.composerBorderAnimation)
            objectWillChange.send()
        }
    }

    var composerFlow: ComposerFlow {
        get { ComposerFlow(rawValue: defaults.string(forKey: DefaultsKeys.composerFlow) ?? "aurora") ?? .aurora }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKeys.composerFlow)
            objectWillChange.send()
        }
    }

    var compressionLevel: CompressionLevel {
        get {
            CompressionLevel(rawValue: defaults.string(forKey: DefaultsKeys.compressionLevel) ?? "standard") ?? .standard
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKeys.compressionLevel)
            objectWillChange.send()
        }
    }

    /// When true, the loop runs build diagnostics after each successful edit.
    /// Diagnostics run through the normal command approval path — this never
    /// silently executes arbitrary commands.
    var verifyAfterEdits: Bool {
        get { defaults.bool(forKey: DefaultsKeys.verifyAfterEdits) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.verifyAfterEdits)
            objectWillChange.send()
        }
    }

    /// Local API server (OpenAI-compatible, loopback-only). When enabled the
    /// app serves /v1/chat/completions etc. on 127.0.0.1:<port>.
    var apiServerEnabled: Bool {
        get { defaults.bool(forKey: DefaultsKeys.apiServerEnabled) }
        set {
            defaults.set(newValue, forKey: DefaultsKeys.apiServerEnabled)
            objectWillChange.send()
        }
    }

    var apiServerPort: Int {
        get {
            let value = defaults.integer(forKey: DefaultsKeys.apiServerPort)
            return value == 0 ? 1234 : value
        }
        set {
            // Keep it in the unprivileged, collision-sane range.
            let clamped = min(max(newValue, 1024), 65_535)
            defaults.set(clamped, forKey: DefaultsKeys.apiServerPort)
            objectWillChange.send()
        }
    }

    private enum DefaultsKeys {
        static let autoApproveEdits = "autoApproveEdits"
        static let autoApproveCommands = "autoApproveCommands"
        static let maxTurns = "maxTurns"
        static let maxTokensPerTurn = "maxTokensPerTurn"
        static let temperature = "temperature"
        static let checkpointingEnabled = "checkpointingEnabled"
        static let verifyAfterEdits = "verifyAfterEdits"
        static let memoryMode = "memoryMode"
        static let compressionLevel = "compressionLevel"
        static let composerFlow = "composerFlow"
        static let showReasoning = "showReasoning"
        static let planMode = "planMode"
        static let appearance = "appearance"
        static let accentPalette = "accentPalette"
        static let composerBorderAnimation = "composerBorderAnimation"
        static let apiServerEnabled = "apiServerEnabled"
        static let apiServerPort = "apiServerPort"
    }
}