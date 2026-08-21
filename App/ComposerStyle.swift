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

/// A restrained native-feeling composer surface. State is communicated by a
/// quiet hairline and a small glow rather than a continuously rotating frame.
struct ComposerBorder: ViewModifier {
    let flow: ComposerFlow
    let phase: ComposerPhase
    var animated: Bool = true

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cornerRadius: CGFloat { Radius.lg }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var stateTint: Color {
        switch phase {
        case .idle: Theme.hairline
        case .focused: Theme.accent
        case .streaming: Theme.info
        case .awaitingApproval: Theme.warning
        }
    }

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: shape)
            .shadow(color: Theme.cardShadow, radius: 10, y: 4)
            .contentShape(shape)
            .onHover { hovering in
                if reduceMotion {
                    isHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        isHovering = hovering
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    borderColor,
                    lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: phase == .idle ? .clear : stateTint.opacity(animated ? 0.055 : 0.035),
                radius: phase == .idle ? 0 : 5)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: phase)
            .accessibilityElement(children: .contain)
    }

    private var borderColor: Color {
        switch phase {
        case .idle:
            return isHovering ? Theme.textTertiary.opacity(0.5) : Theme.hairline
        case .focused:
            return stateTint.opacity(0.34 + (isHovering ? 0.05 : 0))
        case .streaming:
            return stateTint.opacity(0.42 + (isHovering ? 0.05 : 0))
        case .awaitingApproval:
            return stateTint.opacity(0.5 + (isHovering ? 0.05 : 0))
        }
    }
}

extension View {
    /// Quiet toolbar controls: chrome appears on hover or when the control is
    /// carrying non-default state, keeping the editor visually dominant.
    func lfComposerPill(active: Bool) -> some View {
        modifier(ComposerPillModifier(active: active))
    }
}

private struct ComposerPillModifier: ViewModifier {
    let active: Bool
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.medium))
            .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Theme.washBorder(Theme.accent) : .clear,
                                            lineWidth: 1))
            .contentShape(Capsule())
            .onHover { hovering in
                if reduceMotion {
                    isHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHovering = hovering
                    }
                }
            }
            .pointerStyle(isHovering ? .link : .default)
    }

    private var background: Color {
        if active { return Theme.washStrong(Theme.accent) }
        if isHovering { return Theme.surfaceInset.opacity(0.62) }
        return .clear
    }
}
