import Foundation

/// App color appearance. `system` follows macOS; `light`/`dark` force it.
/// Light is the default. Kept Foundation-only (no SwiftUI) so the CLI target
/// can compile this file; the SwiftUI `ColorScheme` mapping lives in the app.
enum AppAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
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
            DefaultsKeys.maxTokensPerTurn: 2048,
            DefaultsKeys.temperature: 0.6,
            DefaultsKeys.checkpointingEnabled: true,
            DefaultsKeys.verifyAfterEdits: false,
            DefaultsKeys.memoryMode: "off",
            DefaultsKeys.compressionLevel: "standard",
            DefaultsKeys.composerFlow: "aurora",
            DefaultsKeys.showReasoning: false,
            DefaultsKeys.planMode: false,
            DefaultsKeys.appearance: AppAppearance.light.rawValue,
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
        static let composerBorderAnimation = "composerBorderAnimation"
        static let apiServerEnabled = "apiServerEnabled"
        static let apiServerPort = "apiServerPort"
    }
}