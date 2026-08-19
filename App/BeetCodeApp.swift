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

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
                .environmentObject(appState.sessions)
                // A real working minimum: sidebar + chat + docked panel need room.
                .frame(minWidth: 960, minHeight: 640)
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
}