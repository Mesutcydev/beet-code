import SwiftUI

// MARK: - Shared settings chrome

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                content
            }

            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opaque elevated card — matches the main window's surfaces; the
        // translucent lfGlass look is reserved for overlay chrome.
        .lfCard()
    }
}

/// One label-left / control-right row, uniform height and spacing.
struct SettingRow<Control: View>: View {
    let label: String
    var value: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                if let value {
                    Text(value)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 24)
            control
                .frame(maxWidth: 420, alignment: .trailing)
        }
        .frame(minHeight: 26)
    }
}

/// Boolean setting rendered as a SettingRow — label left, switch right — so
/// every toggle in the window aligns with the picker/stepper rows around it.
/// All settings toggles use the switch style (no mixed checkboxes).
struct SettingToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(label: label) {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// Compact shortcut editor. Users can type `cmd+shift+p` or the equivalent
/// readable spelling; the field normalizes it when editing finishes.
struct ShortcutEditor: View {
    let placeholder: String
    @Binding var value: String

    var body: some View {
        TextField(placeholder, text: $value)
            .textFieldStyle(.roundedBorder)
            .frame(width: 170)
            .onSubmit {
                value = ShortcutBinding(rawValue: value).canonicalValue
            }
            .help("Use cmd, shift, option, or control followed by a key, for example \(placeholder)")
    }
}

/// Accent palette picker rendered as color swatches. Each swatch shows the
/// palette's light-mode accent; selection draws an accent ring. Every swatch
/// carries a tooltip and VoiceOver label naming the palette.
struct PaletteSwatchPicker: View {
    @Binding var selection: AccentPalette

    var body: some View {
        HStack(spacing: Spacing.md) {
            ForEach(AccentPalette.allCases) { palette in
                swatch(for: palette)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func swatch(for palette: AccentPalette) -> some View {
        let isSelected = palette == selection
        Button {
            selection = palette
        } label: {
            ZStack {
                Circle()
                    .fill(swatchColor(palette))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
                    )
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .lfHoverLift()
        .help(palette.label)
        .accessibilityLabel("\(palette.label) palette")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Static preview color for the swatch — always the palette's light-mode
    /// accent so the picker itself stays readable in either appearance.
    private func swatchColor(_ palette: AccentPalette) -> Color {
        let hex = palette.hexes.accentLight
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

struct TabScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                content
            }
            .padding(Spacing.lg)
        }
        .background(Theme.bg)
    }
}

/// Slim tinted banner for tab-level explanations — deliberately NOT a
/// SettingsCard, so a one-paragraph note doesn't read as a runt card next
/// to the content-rich cards around it.
struct InfoBanner: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.info)
                .frame(width: 30, height: 30)
                .background(Theme.washStrong(Theme.info),
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.md)
        .lfWashCard(Theme.info)
    }
}
