import AppKit
import SwiftUI

/// Shared sidebar section chrome. The whole header is the expand/collapse hit
/// target, but the header stays a text-first divider instead of another raised
/// card. Project names keep their native casing; only the small eyebrow labels
/// use tracking, so user-created workspaces do not feel like decorative badges.
struct SidebarGroupHeader: View {
    var icon: String
    var appIcon: NSImage? = nil
    var name: String
    var count: Int?
    var expanded: Bool = true

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            headerGlyph
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline.opacity(0.65))
                .frame(height: 1)
                .padding(.leading, 28)
        }
        .accessibilityLabel(count.map { "\(name), \($0) chats" } ?? name)
        .accessibilityHint(expanded ? "Collapse" : "Expand")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var headerGlyph: some View {
        if let appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .background(Theme.surfaceInset.opacity(0.72), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}
