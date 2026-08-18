import SwiftUI

/// The Intent picker: the lattice's replacement. Two short chip rows —
/// Roles (what the agent does) and Focus (what context it gets) — plus
/// preset curations. Everything selected here is injected as a plain,
/// auditable preface to the next message; the chips above the composer
/// mirror the selection.
struct IntentPicker: View {
    var store: ComposerStore

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            presetsSection
            rolesSection
            focusSection
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Intent for this turn")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if !store.selection.isEmpty {
                Button("Clear") { store.clearIntent() }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Remove all roles and focus sources")
            }
        }
    }

    // MARK: Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Presets")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(IntentPresets.all) { preset in
                    Button {
                        store.applyPreset(preset)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: preset.glyph)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 16)
                            Text(preset.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surfaceInset.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .lfHoverLift()
                    .help("\(preset.summary) Replaces the current roles.")
                }
            }
        }
    }

    // MARK: Roles

    private var rolesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Roles — what the agent does")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(IntentRole.allCases) { role in
                    let selected = store.selection.roles.contains(role)
                    Button {
                        store.toggleRole(role)
                    } label: {
                        chipLabel(role.label, glyph: role.glyph, selected: selected, tint: Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .lfHoverLift()
                    // The tooltip shows the exact injected sentence — the
                    // user can audit what the model will be told.
                    .help(role.instruction)
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
        }
    }

    // MARK: Focus

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Focus — extra context")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(FocusSource.allCases) { source in
                    let selected = store.selection.focus.contains(source)
                    let availability = store.availability(for: source)
                    Button {
                        store.toggleFocus(source)
                    } label: {
                        chipLabel(source.label, glyph: source.glyph, selected: selected, tint: Theme.info)
                            .opacity(availability.isAvailable ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .disabled(!availability.isAvailable && !selected)
                    .lfHoverLift()
                    .help(focusHelp(source, availability: availability))
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
        }
    }

    private func focusHelp(_ source: FocusSource, availability: FocusAvailability) -> String {
        switch availability {
        case .available:
            return source.summary
        case .unavailable(let reason):
            return reason
        }
    }

    // MARK: Footer

    private var footer: some View {
        Text("Sent as a structured preface with your next message. Empty sources are marked “(nothing found)” — never fabricated.")
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Building blocks

    private func chipLabel(_ title: String, glyph: String, selected: Bool, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .frame(width: 16)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(selected ? tint : Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(selected ? tint.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .strokeBorder(selected ? tint.opacity(0.5) : Theme.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
    }
}
