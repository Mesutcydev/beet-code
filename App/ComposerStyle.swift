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

    private var cornerRadius: CGFloat { Radius.lg }
    private var borderWidth: CGFloat { phase == .idle ? 1.5 : 2.5 }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            // One elevated card: the composer floats on the raised surface
            // above the window bg — not a recessed input well.
            .background(Theme.surface, in: shape)
            // Outer glow (streaming/approval only): rendered BEHIND the
            // surface so only the bleed beyond the card edge shows — the
            // light appears to radiate without hazing the input area.
            .background {
                if animated && (phase == .streaming || phase == .awaitingApproval) {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let progress = (t / flow.cycleSeconds).truncatingRemainder(dividingBy: 1)
                        borderGradient(angle: .degrees(progress * 360))
                            .blur(radius: 7)
                            .opacity(0.55)
                    }
                }
            }
            // Baseline edge so the card stays defined while the gradient is
            // dim at idle.
            .overlay {
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
            }
            // Signature: the animated light tracing the FULL perimeter of
            // the composer, intensifying idle → focused → streaming.
            .overlay {
                if animated {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let progress = (t / flow.cycleSeconds).truncatingRemainder(dividingBy: 1)
                        borderGradient(angle: .degrees(progress * 360))
                    }
                } else {
                    borderGradient(angle: .degrees(45))
                }
            }
    }

    /// The gradient stroke: an angular gradient rotating around the card's
    /// center, masked to the rounded-rectangle border so it traces the whole
    /// outline. The wrapped color palette keeps the sweep seamless.
    private func borderGradient(angle: Angle) -> some View {
        AngularGradient(colors: flow.colors, center: .center, angle: angle)
            .opacity(phase.borderOpacity)
            .mask {
                shape.strokeBorder(lineWidth: borderWidth)
            }
    }
}

extension View {
    /// The accessory row's single pill language — attach, model pill,
    /// Intent, Plan and Reasoning all share this capsule: surfaceInset fill
    /// + secondary text at rest, an accent wash + border + accent text when
    /// active. Type is caption; 11pt icons are set at the call site.
    func lfComposerPill(active: Bool) -> some View {
        self
            .font(.caption.weight(.medium))
            .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(active ? Theme.washStrong(Theme.accent) : Theme.surfaceInset, in: Capsule())
            .overlay(Capsule().strokeBorder(
                active ? Theme.washBorder(Theme.accent) : .clear, lineWidth: 1))
            .lfHoverLift()
    }
}
