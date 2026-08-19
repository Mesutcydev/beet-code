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
    // The active accent palette — read at DRAW time by the dynamic colors
    // below, so a palette switch takes effect live without recreating views.
    // Only ever mutated from the main actor via applyPalette.
    nonisolated(unsafe) static var currentPalette: AccentPalette = .beetRed

    // The active appearance — read at DRAW time by the dynamic colors below
    // so a Beet-mode switch re-tints every neutral live. Only ever mutated
    // from the main actor via applyAppearance.
    nonisolated(unsafe) static var currentAppearance: AppAppearance = .system

    /// Applies the user's palette choice. Called once at launch and again on
    /// every change (mirrors `applyAppearance`).
    @MainActor static func applyPalette(_ palette: AccentPalette) {
        currentPalette = palette
    }

    /// Palette-driven dynamic color: resolves the CURRENT palette's hex
    // pair for the active appearance on every draw.
    private static func paletteColor(
        light: KeyPath<AccentPalette.Hexes, UInt32>,
        dark: KeyPath<AccentPalette.Hexes, UInt32>
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hexes = currentPalette.hexes
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? hexes[keyPath: dark] : hexes[keyPath: light]
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green:   CGFloat((hex >> 8) & 0xFF) / 255,
                           blue:    CGFloat(hex & 0xFF) / 255,
                           alpha:   1)
        })
    }

    // Neutrals — one cohesive cool-slate hue, deepest (bg) to raised (inset).
    // Dark steps carry real separation: the window bg sits deep so cards
    // visibly lift off it, and inset wells/chips lift off cards — without
    // these steps, dark mode reads as one flat sheet. Light inset is one
    // full step darker than the page so inset wells + chips keep visible
    // separation (U9).
    //
    // Beet mode anchors the ENTIRE ramp on the brand color — Pantone
    // 19-2030 TCX Beet Red (#7A1F3D) is the window background itself, not
    // a whisper of plum on black. Cards lift one step lighter, inset wells
    // step darker, hairlines stay inside the beet family — one hue, four
    // depths, so the whole window reads as solid beet.
    static let bg           = Color.dynamic(light: 0xF6F7F9, dark: 0x0C0E14, beet: 0x7A1F3D)
    static let surface      = Color.dynamic(light: 0xFFFFFF, dark: 0x181C26, beet: 0xA84462)
    static let surfaceInset = Color.dynamic(light: 0xE3E6EB, dark: 0x232837, beet: 0x5E1630)
    static let hairline     = Color.dynamic(light: 0xE1E4EA, dark: 0x343B4E, beet: 0xC45A7C)

    // Text tiers. Dark secondary/tertiary sit a touch brighter than the
    // neutrals around them so captions stay legible on the lifted surfaces;
    // beet tiers are warm pinks tuned to stay readable on the saturated
    // Pantone background (secondary ≈ 5.6:1, tertiary ≈ 3.5:1).
    static let textPrimary   = Color.dynamic(light: 0x14161A, dark: 0xF2F4F8, beet: 0xFDF2F6)
    static let textSecondary = Color.dynamic(light: 0x5B616E, dark: 0xA3AABB, beet: 0xE7B8C8)
    static let textTertiary  = Color.dynamic(light: 0x8A909C, dark: 0x717889, beet: 0xC08CA0)

    /// Elevation shadow: a whisper in light mode, much deeper in dark —
    /// after the surface lift above, the shadow is what separates a card
    /// from the window chrome around it.
    static let cardShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.45)
            : NSColor.black.withAlphaComponent(0.12)
    })

    // Accent — palette-driven. Default is Beet Red (Pantone 19-2030 TCX,
    // #7A1F3D); switchable in Settings → Appearance. In dark mode every
    // palette ships a same-hue lift so it stays vivid on black.
    static var accent: Color { paletteColor(light: \.accentLight, dark: \.accentDark) }
    static var accentBright: Color { paletteColor(light: \.brightLight, dark: \.brightDark) }
    static var accentSoft: Color { accent.opacity(0.14) }

    // Status — tuned per mode so they never blow out on the deep dark.
    static let success = Color.dynamic(light: 0x1EA672, dark: 0x35D6A0)
    static let warning = Color.dynamic(light: 0xC77700, dark: 0xF5B23D)
    static let danger  = Color.dynamic(light: 0xDC3B4B, dark: 0xFF6B78)
    static let info    = Color.dynamic(light: 0x2B7FFF, dark: 0x5AA0FF)

    // Tint washes — the ONLY opacities views may use for tinted fills and
    // borders, so "washed" surfaces read identically everywhere in the app.
    // (0.07/0.10/0.12/0.14/0.16/0.18/0.30/0.35/0.38 all used to appear.)
    static func wash(_ tint: Color) -> Color { tint.opacity(0.10) }
    static func washStrong(_ tint: Color) -> Color { tint.opacity(0.16) }
    static func washBorder(_ tint: Color) -> Color { tint.opacity(0.35) }

    /// Palette wash for the primary (user) surface and glows — accent to
    // bright variant, resolved live from the current palette.
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentBright],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Keep AppKit's app-wide appearance in lockstep with the user's setting so
    /// the dynamic `NSColor` providers above resolve to the *forced* scheme —
    /// not merely the OS one — matching SwiftUI's `preferredColorScheme`.
    /// Beet mode forces dark AppKit chrome; its plum neutrals come from the
    /// `beet:` hexes, which read `currentAppearance` at draw time.
    @MainActor static func applyAppearance(_ appearance: AppAppearance) {
        currentAppearance = appearance
        NSApplication.shared.appearance = switch appearance {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark, .beet: NSAppearance(named: .darkAqua)
        }
        // NavigationSplitView's unused trailing gutter is the window
        // background — leave it themed, never default black.
        let fill = NSColor(Theme.bg)
        for window in NSApplication.shared.windows {
            window.backgroundColor = fill
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

/// The centered reading column shared by the transcript and the composer.
/// Fluid up to a wide cap: narrow windows use nearly the full width, and
/// only very wide windows see side margins — never a skinny 760pt strip
/// floating in dead space.
enum ContentColumn {
    static let maxWidth: CGFloat = 1100
}

/// App typography. Prose stays in proportional SF; anything the user TYPES
/// as a coding task uses SF Mono — the same monospaced voice as the diff,
/// command and diagnostics surfaces, so input and output read as one
/// coding environment.
enum AppFont {
    /// The composer editor (and any future code-forward input).
    static let editor = Font.system(size: 14, design: .monospaced)
}

/// Spacing — 4pt grid. Use these instead of ad-hoc padding literals.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

extension Color {
    /// A color that resolves light/dark from a hex pair with no intermediate
    /// `Color`→`NSColor` round-trip (keeps the sRGB values exact). `beet`
    /// overrides the dark value while Beet mode is active — Beet is a dark
    /// appearance, so callers that don't pass it fall through to `dark`.
    static func dynamic(light: UInt32, dark: UInt32, beet: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex: UInt32
            if isDark, Theme.currentAppearance == .beet, let beet {
                hex = beet
            } else {
                hex = isDark ? dark : light
            }
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

    /// Cursor/ChatGPT-style hover affordance for small chips and accessory
    /// buttons: a +0.03 brightness lift, a pointing cursor, and a hairline
    /// tint so interactive controls are never mistaken for static text.
    /// Reduce Motion is respected automatically (no animation, just a
    /// pointer + brightness change — both non-animated).
    func lfHoverLift() -> some View {
        modifier(HoverLiftModifier())
    }

    /// Semantic accent-washed card (approval / question / plan / error).
    func lfWashCard(_ tint: Color, radius: CGFloat = Radius.lg) -> some View {
        background(Theme.wash(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.washBorder(tint), lineWidth: 1))
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
        if reduceTransparency || Theme.currentAppearance == .beet {
            // Beet mode tints EVERY surface — system materials are neutral
            // gray-blue and would break the plum ramp, so glass falls back
            // to the opaque themed surface there too.
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

/// Hover affordance (U5): pointer cursor + a small brightness lift so chips
/// and accessory buttons read as interactive. pointerStyle is macOS 15+,
/// which is our deployment target — no availability gate needed.
private struct HoverLiftModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .pointerStyle(hovering ? .link : .default)
            .brightness(hovering ? 0.03 : 0)
    }
}
