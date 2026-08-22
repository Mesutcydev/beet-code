import AppKit
import SwiftUI

// MARK: - Settings window

/// Tabbed, card-based settings. Four native tabs (General / Agent /
/// Providers / Plugins); every section is a Theme-styled card with an icon
/// header, consistent padding, and a short footer.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case agent = "Agent"
        case providers = "Providers"
        case plugins = "Plugins"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .agent: "cpu"
            case .providers: "key"
            case .plugins: "puzzlepiece"
            }
        }
    }

    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            AgentTab()
                .tabItem { Label("Agent", systemImage: "cpu") }
                .tag(Tab.agent)
            ProvidersTab()
                .tabItem { Label("Providers", systemImage: "key") }
                .tag(Tab.providers)
            PluginsTab()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece") }
                .tag(Tab.plugins)
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .openProviderSettings)) { _ in
            tab = .providers
        }
    }
}
