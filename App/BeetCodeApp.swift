import SwiftUI

/// Maps the persisted appearance setting onto SwiftUI. `nil` means "follow
/// the OS"; `.light`/`.dark` force it. Light is the app default.
extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct BeetCodeApp: App {
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