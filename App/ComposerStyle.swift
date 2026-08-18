import SwiftUI

/// The SwiftUI palette for each composer flow preset. The enum itself lives
/// in Core (ComposerFlow.swift) so SettingsStore and the CLI can see it
/// without importing the UI layer.
extension ComposerFlow {
    /// Colors for the animated border gradient.
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
        case .idle: 0.35
        case .focused: 0.7
        case .streaming: 1.0
        case .awaitingApproval: 1.0
        }
    }
}

/// Animated gradient border around the composer. The gradient phase advances
/// continuously; speed and colors come from the selected flow preset. When
/// `animated` is false (Settings → Composer), the underline is a static
/// accent gradient — same identity, zero motion.
struct ComposerBorder: ViewModifier {
    let flow: ComposerFlow
    let phase: ComposerPhase
    var animated: Bool = true
    @State private var animationPhase: Double = 0

    func body(content: Content) -> some View {
        content
            // A proper inset input well: the field reads as recessed against
            // the composer's raised surface.
            .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // Signature: an animated accent underline that intensifies as the
            // composer moves idle → focused → streaming.
            .overlay(alignment: .bottom) {
                if animated {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let progress = (t / flow.cycleSeconds).truncatingRemainder(dividingBy: 1)
                        LinearGradient(
                            colors: flow.colors,
                            startPoint: .leading,
                            endPoint: .trailing)
                            .hueRotation(.degrees(progress * 360))
                            .opacity(phase.borderOpacity)
                            .frame(height: phase == .idle ? 2 : 3)
                            .clipShape(Capsule())
                            .padding(.horizontal, 10)
                            .padding(.bottom, 3)
                    }
                } else {
                    LinearGradient(colors: flow.colors, startPoint: .leading, endPoint: .trailing)
                        .opacity(phase.borderOpacity * 0.8)
                        .frame(height: phase == .idle ? 2 : 3)
                        .clipShape(Capsule())
                        .padding(.horizontal, 10)
                        .padding(.bottom, 3)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(phase == .idle ? Theme.hairline : Theme.accent.opacity(0.5),
                                  lineWidth: 1)
            }
    }
}