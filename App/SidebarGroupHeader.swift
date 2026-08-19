import AppKit
import SwiftUI

/// Shared sidebar group chrome. The whole plate is the expand/collapse
/// hit target — not just the trailing chevron macOS puts on Section headers.
struct SidebarGroupHeader: View {
    var icon: String
    var appIcon: NSImage? = nil
    var name: String
    var count: Int?
    var expanded: Bool = true

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            headerGlyph
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.washStrong(Theme.accent), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
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
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Theme.washStrong(Theme.accent),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
