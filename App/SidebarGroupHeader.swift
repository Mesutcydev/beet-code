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
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 9)
            headerGlyph
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.top, 11)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
                .frame(width: 15, height: 15)
                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        } else {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 15, height: 15)
        }
    }
}
