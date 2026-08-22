import SwiftUI

/// Faded window atmosphere — the classical engraving sits behind the
/// transcript the way Hermes sits a map behind chat: present if you look
/// for it, never competing with text.
struct AtmosphereBackground: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg
                if !reduceTransparency {
                    Image("WindowAtmosphere")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(artOpacity)
                        .blendMode(blend)
                        .saturation(0.55)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    Theme.bg.opacity(washOpacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Theme.bg)
    }

    private var artOpacity: Double {
        switch settings.appearance {
        case .light: 0.05
        case .dark: 0.04
        case .beet: 0.08
        case .system: 0.04
        }
    }

    private var washOpacity: Double {
        switch settings.appearance {
        case .light: 0.62
        case .beet: 0.50
        case .dark, .system: 0.62
        }
    }

    private var blend: BlendMode {
        settings.appearance == .light ? .multiply : .plusLighter
    }
}
