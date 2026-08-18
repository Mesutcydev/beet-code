import AppKit
import SwiftUI

/// Beet Code's single source of truth for color. Every surface, text tier and
/// status color resolves through here so light and dark stay coherent by
/// construction instead of per-view `colorScheme ? … : …` guesses.
///
/// Aesthetic: futuristic, calm, developer-native. Cool near-neutral surfaces,
/// a deep glassy dark, and one electric indigo-violet accent that reads as
/// "agentic" without shouting.
enum Theme {
    // Neutrals — one cohesive cool-slate hue, deepest (bg) to raised (inset).
    // Dark steps are deliberately close so bg→surface→inset reads as gentle
    // depth, never as clashing tones.
    static let bg           = Color.dynamic(light: 0xF6F7F9, dark: 0x0E1016)
    static let surface      = Color.dynamic(light: 0xFFFFFF, dark: 0x161922)
    static let surfaceInset = Color.dynamic(light: 0xEDEFF3, dark: 0x1F2330)
    static let hairline     = Color.dynamic(light: 0xE1E4EA, dark: 0x2C3140)

    // Text tiers.
    static let textPrimary   = Color.dynamic(light: 0x14161A, dark: 0xF2F4F8)
    static let textSecondary = Color.dynamic(light: 0x5B616E, dark: 0x9AA1B2)
    static let textTertiary  = Color.dynamic(light: 0x8A909C, dark: 0x646B7B)

    // Accent — electric indigo-violet, lifted in dark so it stays vivid on black.
    static let accent       = Color.dynamic(light: 0x6C5CE7, dark: 0x8B7BFF)
    static let accentBright = Color.dynamic(light: 0x5B4BE0, dark: 0x9D90FF)
    static var accentSoft: Color { accent.opacity(0.14) }

    // Status — tuned per mode so they never blow out on the deep dark.
    static let success = Color.dynamic(light: 0x1EA672, dark: 0x35D6A0)
    static let warning = Color.dynamic(light: 0xC77700, dark: 0xF5B23D)
    static let danger  = Color.dynamic(light: 0xDC3B4B, dark: 0xFF6B78)
    static let info    = Color.dynamic(light: 0x2B7FFF, dark: 0x5AA0FF)

    /// Futuristic accent wash for the primary (user) surface and glows.
    static let accentGradient = LinearGradient(
        colors: [Color.dynamic(light: 0x6C5CE7, dark: 0x7C6CFF),
                 Color.dynamic(light: 0x8E7BFF, dark: 0xB49BFF)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Keep AppKit's app-wide appearance in lockstep with the user's setting so
    /// the dynamic `NSColor` providers above resolve to the *forced* scheme —
    /// not merely the OS one — matching SwiftUI's `preferredColorScheme`.
    @MainActor static func applyAppearance(_ appearance: AppAppearance) {
        NSApplication.shared.appearance = switch appearance {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }
}

/// Corner radii — one scale, used everywhere for a consistent silhouette.
enum Radius {
    static let sm: CGFloat = 7
    static let md: CGFloat = 11
    static let lg: CGFloat = 15
    static let xl: CGFloat = 20
}

extension Color {
    /// A color that resolves light/dark from a hex pair with no intermediate
    /// `Color`→`NSColor` round-trip (keeps the sRGB values exact).
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green:   CGFloat((hex >> 8) & 0xFF) / 255,
                           blue:    CGFloat(hex & 0xFF) / 255,
                           alpha:   1)
        })
    }

    /// Convenience for one-off literals (e.g. gradients).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension View {
    /// Standard elevated card: raised surface + hairline border.
    func lfCard(radius: CGFloat = Radius.lg) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// Semantic accent-washed card (approval / question / plan / error).
    func lfWashCard(_ tint: Color, radius: CGFloat = Radius.lg) -> some View {
        background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(tint.opacity(0.38), lineWidth: 1))
    }

    /// Native Liquid Glass surface, ported from the Vamp Mac client recipe
    /// (MacClient/Sources/MacBrand.swift): geometry-locked glass background
    /// that never steals clicks, `.regular` glass for content-bearing
    /// surfaces (legible over busy content), `.clear` for chrome, material
    /// fallbacks on pre-macOS 26, opaque fallback for Reduce Transparency.
    /// Pass `hovering` for the +0.025 brightness lift Vamp's BrandCard uses.
    func lfGlass(
        radius: CGFloat = Radius.lg,
        contentLegibility: Bool = true,
        hovering: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .modifier(LFGlassModifier(shape: shape, contentLegibility: contentLegibility))
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .brightness(hovering ? 0.025 : 0)
    }
}

/// Vamp-style availability-gated glass fill. Kept out of `lfGlass` so the
/// #available dance lives in exactly one place.
private struct LFGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let contentLegibility: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Theme.surface, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content.background {
                GeometryReader { proxy in
                    Color.clear
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .glassEffect(
                            contentLegibility ? .regular : .clear,
                            in: shape)
                        .allowsHitTesting(false)
                }
            }
        } else {
            content.background(
                contentLegibility ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial),
                in: shape)
        }
    }
}
