import SwiftUI

/// The SwiftUI palette for each composer flow preset. The enum itself lives
/// in Core (ComposerFlow.swift) so SettingsStore and the CLI can see it
/// without importing the UI layer.
extension ComposerFlow {
    /// Colors for the animated border gradient. Each palette wraps (first
    /// color repeated last) so the rotating sweep is seamless.
    var colors: [Color] {
        switch self {
        case .aurora: [.purple, .pink, .orange, .purple]
        case .ember: [.orange, .red, .yellow, .orange]
        case .ocean: [.teal, .blue, .cyan, .teal]
        // .primary adapts: near-black in light mode, near-white in dark, so
        // the graphite shimmer stays visible under either appearance.
        case .graphite: [.gray, .secondary, Color.primary.opacity(0.5), .gray]
        }
    }
}

/// The state the composer renders for: drives color intensity and the
/// animated border's meaning.
enum ComposerPhase: Equatable {
    case idle
    case focused
    case streaming
    case awaitingApproval

    var borderOpacity: Double {
        switch self {
        case .idle: 0.45
        case .focused: 0.75
        case .streaming: 1.0
        case .awaitingApproval: 1.0
        }
    }
}

/// Animated gradient border around the ENTIRE composer card. A rotating
/// angular gradient is masked to the card's rounded-rectangle stroke, so the
/// light travels the full perimeter — top, sides and bottom — instead of the
/// old bottom-only underline. Intensity tracks the composer phase
/// (idle → focused → streaming), and streaming/approval adds a soft outer
/// glow. When `animated` is false (Settings → Composer), the border is a
/// static gradient — same identity, zero motion.
struct ComposerBorder: ViewModifier {
    let flow: ComposerFlow
    let phase: ComposerPhase
    var animated: Bool = true

    @State private var isHovering = false

    private var cornerRadius: CGFloat { Radius.lg }
    private var borderWidth: CGFloat { phase == .idle ? 1.5 : 2.5 }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        // Idle stays still until the user approaches the surface. Focus,
        // streaming, approval, and hover all make the perimeter come alive;
        // this gives the border an interaction model instead of a permanent
        // animated wallpaper.
        // The trace is the composer's identity, so it stays alive even while
        // idle. Focus/hover only change its intensity; they never make the
        // signature disappear and leave a dead-looking card behind.
        let shouldAnimate = animated
        content
            // One elevated card: the composer floats on the raised surface
            // above the window bg — not a recessed input well.
            .background(Theme.surface, in: shape)
            // A whisper of elevation so the card floats over the window bg —
            // appearance-aware, since dark mode needs a far deeper shadow.
            .shadow(color: Theme.cardShadow, radius: 6, y: 2)
            .contentShape(shape)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.18)) {
                    isHovering = hovering
                }
            }
            // Outer glow (streaming/approval only): rendered BEHIND the
            // surface so only the bleed beyond the card edge shows — the
            // light appears to radiate without hazing the input area.
            // allowsHitTesting(false) on every decorative layer: without it
            // the overlay swallows clicks meant for the composer's buttons.
            .background {
                if shouldAnimate && (phase == .streaming || phase == .awaitingApproval) {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let progress = (t / flow.cycleSeconds).truncatingRemainder(dividingBy: 1)
                        borderGradient(angle: .degrees(progress * 360))
                            .blur(radius: 7)
                            .opacity(isHovering ? 0.70 : 0.55)
                    }
                    .allowsHitTesting(false)
                }
            }
            // Baseline edge so the card stays defined while the gradient is
            // dim at idle.
            .overlay {
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            // Signature: the animated light tracing the FULL perimeter of
            // the composer, intensifying idle → focused → streaming.
            .overlay {
                if shouldAnimate {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let progress = (t / flow.cycleSeconds).truncatingRemainder(dividingBy: 1)
                        borderGradient(angle: .degrees(progress * 360))
                    }
                    .allowsHitTesting(false)
                } else {
                    borderGradient(angle: .degrees(45))
                        .allowsHitTesting(false)
                }
            }
    }

    /// The gradient stroke: an angular gradient rotating around the card's
    /// center, masked to the rounded-rectangle border so it traces the whole
    /// outline. The wrapped color palette keeps the sweep seamless.
    private func borderGradient(angle: Angle) -> some View {
        AngularGradient(colors: signatureColors, center: .center, angle: angle)
            .opacity(min(1, phase.borderOpacity + (isHovering ? 0.10 : 0)))
            .mask {
                shape.strokeBorder(lineWidth: borderWidth)
            }
    }

    /// The selected flow remains recognizable, but the accent is woven into
    /// every palette so the light belongs to Beet Code's visual system rather
    /// than looking like an unrelated rainbow effect.
    private var signatureColors: [Color] {
        let palette = flow.colors
        return [
            palette[0].opacity(0.06),
            Theme.accent.opacity(0.40),
            palette[1].opacity(0.75),
            Theme.accentBright,
            Color.white.opacity(0.90),
            palette[2].opacity(0.40),
            palette[0].opacity(0.06),
        ]
    }
}

extension View {
    /// Shared control language for the accessory rail. These are deliberately
    /// not pills: the composer is a command line, so active controls are
    /// carried by a quiet wash and a short trace rather than a row of badges.
    func lfComposerPill(active: Bool) -> some View {
        self
            .font(.caption.weight(.medium))
            .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .frame(minHeight: 26)
            .background(active ? Theme.washStrong(Theme.accent) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottom) {
                if active {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 20, height: 2)
                        .padding(.bottom, 0)
                }
            }
            .lfHoverLift()
    }
}
