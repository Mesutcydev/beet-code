import SwiftUI

/// Application delegate for lifecycle events SwiftUI's `App` can't express.
final class BeetCodeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous best-effort: engines' async unload path can't run on
        // the way out, so registered child processes (llama-server) get a
        // plain SIGTERM here.
        ChildProcessRegistry.terminateAll()
    }
}

/// Maps the persisted appearance setting onto SwiftUI. `nil` means "follow
/// the OS"; `.light`/`.dark` force it; `.beet` forces dark chrome (its
/// beet-tinted neutrals come from Theme, not the system scheme).
extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .beet: .dark
        }
    }
}

@main
struct BeetCodeApp: App {
    // Termination hook: SIGTERM any registered child processes (llama-server
    // backing a resident GGUF model) so they never outlive the app.
    @NSApplicationDelegateAdaptor(BeetCodeAppDelegate.self) private var appDelegate
    // AppState is an ObservableObject the app OWNS: StateObject guarantees
    // exactly one instance across view updates.
    @StateObject private var appState = AppState()
    // Observing the settings store re-applies the color scheme live when the
    // user changes Appearance in Settings.
    @ObservedObject private var settings = SettingsStore.shared

    init() {
        // CLI early-exit (Phase 22): `beetcode intel <command>` runs the
        // intelligence CLI and terminates before any UI or app state boots.
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "intel" {
            let code = IntelligenceCLIRunner.run(Array(arguments.dropFirst(2)))
            Foundation.exit(code)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
                .environmentObject(appState.sessions)
                // A real working minimum: sidebar + chat + docked panel need room.
                .frame(minWidth: 520, minHeight: 640)
                .preferredColorScheme(settings.appearance.colorScheme)
                // Keep AppKit's appearance in sync so Theme's dynamic NSColors
                // resolve to the forced scheme, not just the OS one.
                .task(id: settings.appearance) { Theme.applyAppearance(settings.appearance) }
                // Apply the accent palette at launch and on every change —
                // Theme's palette-driven colors resolve live.
                .task(id: settings.accentPalette) { Theme.applyPalette(settings.accentPalette) }
                .task {
                    DiagnosticsCenter.shared.record(
                        .system, "App launched",
                        detail: "appearance: \(settings.appearance.rawValue) · palette: \(settings.accentPalette.rawValue)")
                }
        }
        .defaultSize(width: 1240, height: 840)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            // ⌘M is macOS's standard Minimize shortcut; Model Manager gets
            // ⇧⌘M so neither command fights the system.
            CommandGroup(after: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(name: .newChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("Stop Agent") {
                    NotificationCenter.default.post(name: .stopAgent, object: nil)
                }
                .keyboardShortcut(
                    ShortcutBinding(rawValue: settings.stopShortcut).keyEquivalent,
                    modifiers: ShortcutBinding(rawValue: settings.stopShortcut).eventModifiers)
                Button("Send") {
                    NotificationCenter.default.post(name: .sendMessage, object: nil)
                }
                .keyboardShortcut(
                    ShortcutBinding(rawValue: settings.sendShortcut).keyEquivalent,
                    modifiers: ShortcutBinding(rawValue: settings.sendShortcut).eventModifiers)
                Button("Toggle Plan Mode") {
                    settings.planMode.toggle()
                }
                .keyboardShortcut(
                    ShortcutBinding(rawValue: settings.planShortcut).keyEquivalent,
                    modifiers: ShortcutBinding(rawValue: settings.planShortcut).eventModifiers)
                Button("Model Manager…") {
                    NotificationCenter.default.post(name: .openModelManager, object: nil)
                }
                .keyboardShortcut("M", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}

extension Notification.Name {
    static let openModelManager = Notification.Name("com.beetcode.openModelManager")
    static let openRemoteAccess = Notification.Name("com.beetcode.openRemoteAccess")
    static let toggleBrowserPanel = Notification.Name("com.beetcode.toggleBrowserPanel")
    static let toggleSimulatorPanel = Notification.Name("com.beetcode.toggleSimulatorPanel")
    static let toggleDiagnosticsPanel = Notification.Name("com.beetcode.toggleDiagnosticsPanel")
    static let gitStatus = Notification.Name("com.beetcode.gitStatus")
    static let gitDiff = Notification.Name("com.beetcode.gitDiff")
    static let undoCheckpoint = Notification.Name("com.beetcode.undoCheckpoint")
    static let exportChatMarkdown = Notification.Name("com.beetcode.exportChatMarkdown")
    static let exportChatJSON = Notification.Name("com.beetcode.exportChatJSON")
    static let exportTaskBundle = Notification.Name("com.beetcode.exportTaskBundle")
    static let newChat = Notification.Name("com.beetcode.newChat")
    static let stopAgent = Notification.Name("com.beetcode.stopAgent")
    static let sendMessage = Notification.Name("com.beetcode.sendMessage")
}
