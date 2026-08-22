import AppKit
import SwiftUI

enum CapabilityMode: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case enabled = "On"
    case disabled = "Off"

    var id: String { rawValue }

    var value: Bool? {
        switch self {
        case .automatic: nil
        case .enabled: true
        case .disabled: false
        }
    }

    init(value: Bool?) {
        switch value {
        case .some(true): self = .enabled
        case .some(false): self = .disabled
        case .none: self = .automatic
        }
    }
}

/// A model-aware effort control with a small "reactor" metaphor. It keeps the
/// familiar one-choice semantics of a picker, but exposes the supported modes
/// as a visible energy ladder so the user can understand the latency/quality
/// trade-off without opening a generic menu.
struct ReasoningEffortPicker: View {
    let profile: RemoteModelProfile
    @Binding var selection: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    private var options: [ReasoningEffort] { profile.effectiveReasoningEfforts }

    private var selectedOption: ReasoningEffort? {
        guard let selection else { return nil }
        return options.first { $0.rawValue == selection.lowercased() }
    }

    var body: some View {
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Label("Reasoning reactor", systemImage: "atom")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(selectionLabel)
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(reactorTint)
                }

                HStack(spacing: 4) {
                    reactorButton(
                        id: "automatic",
                        title: "Auto",
                        subtitle: "provider default",
                        glyph: "wand.and.stars",
                        tint: Theme.accent,
                        isSelected: selection == nil) {
                            choose(nil)
                        }

                    ForEach(options) { option in
                        reactorButton(
                            id: option.id,
                            title: option.label,
                            subtitle: option.rawValue,
                            glyph: option.glyph,
                            tint: tint(for: option),
                            isSelected: selectedOption == option) {
                                choose(option.rawValue)
                            }
                    }
                }
                .padding(4)
                .background(
                    LinearGradient(
                        colors: [Theme.surfaceInset, Theme.bg],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1))

                HStack(spacing: 6) {
                    Circle()
                        .fill(reactorTint)
                        .frame(width: 6, height: 6)
                        .shadow(color: reactorTint.opacity(0.7), radius: 4)
                    Text(selectionDetail)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text("\(options.count) modes")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var selectionLabel: String {
        selectedOption?.label ?? "Auto"
    }

    private var selectionDetail: String {
        if let selectedOption { return "\(selectedOption.detail) · wire: \(selectedOption.rawValue)" }
        if let defaultEffort = profile.effectiveDefaultReasoningEffort {
            return "The provider chooses its default · currently \(defaultEffort)"
        }
        return "The provider chooses the balance automatically"
    }

    private var reactorTint: Color {
        if let selectedOption { return tint(for: selectedOption) }
        return Theme.accent
    }

    private func tint(for option: ReasoningEffort) -> Color {
        switch option.rawValue {
        case "none", "minimal": Theme.info
        case "low", "medium": Theme.accent
        case "high", "xhigh": Theme.warning
        case "max": Theme.danger
        default: Theme.accent
        }
    }

    private func reactorButton(
        id: String,
        title: String,
        subtitle: String,
        glyph: String,
        tint: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.washStrong(tint))
                            .matchedGeometryEffect(id: "reactor-selection", in: selectionNamespace)
                    }
                    Image(systemName: glyph)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? tint : Theme.textTertiary)
                }
                .frame(height: 22)
                Text(title)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(isSelected ? tint : Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 4)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(ReactorNodeButtonStyle(isSelected: isSelected, reduceMotion: reduceMotion))
        .help(isSelected ? "Selected: \(title) (\(subtitle))" : "Use \(title) reasoning (\(subtitle))")
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityHint(isSelected ? "Selected" : "\(selectionDetail)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .id(id)
    }

    private func choose(_ effort: String?) {
        if reduceMotion {
            selection = effort
        } else {
            withAnimation(.snappy(duration: 0.22)) {
                selection = effort
            }
        }
    }
}

struct ReactorNodeButtonStyle: ButtonStyle {
    let isSelected: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.wash(Theme.accent) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Theme.washBorder(Theme.accent) : Color.clear, lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Capability controls for a model whose endpoint identity may come from
/// OpenCode or another compatible gateway. The override is keyed by the
/// exact provider id + model pair, so two gateways using the same model name
/// cannot accidentally share limits or tool flags.
struct RemoteModelCapabilityEditor: View {
    let profile: RemoteModelProfile

    @State private var contextWindow = ""
    @State private var outputTokens = ""
    @State private var vision: CapabilityMode = .automatic
    @State private var tools: CapabilityMode = .automatic
    @State private var reasoning: CapabilityMode = .automatic
    @State private var reasoningEffort: String?
    @State private var temperature: CapabilityMode = .automatic

    init(profile: RemoteModelProfile) {
        self.profile = profile
        let override = AppPreferencesStore.shared.remoteModelOverride(endpoint: profile.endpoint())
        _contextWindow = State(initialValue: override?.contextWindow.map(String.init) ?? "")
        _outputTokens = State(initialValue: override?.maxOutputTokens.map(String.init) ?? "")
        _vision = State(initialValue: CapabilityMode(value: override?.supportsVision))
        _tools = State(initialValue: CapabilityMode(value: override?.supportsTools))
        _reasoning = State(initialValue: CapabilityMode(value: override?.supportsReasoning))
        _reasoningEffort = State(initialValue: override?.reasoningEffort)
        _temperature = State(initialValue: CapabilityMode(value: override?.supportsTemperature))
    }

    private var effectiveProfile: RemoteModelProfile {
        profile.applying(AppPreferencesStore.shared.remoteModelOverride(endpoint: profile.endpoint()))
    }

    var body: some View {
        DisclosureGroup("Model capability overrides") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(effectiveSummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.sm) {
                    TextField("Context window", text: $contextWindow)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    TextField("Max output", text: $outputTokens)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                }

                capabilityPicker("Tools", selection: $tools)
                capabilityPicker("Reasoning", selection: $reasoning)
                ReasoningEffortPicker(profile: effectiveProfile, selection: $reasoningEffort)
                capabilityPicker("Vision", selection: $vision)
                capabilityPicker("Temperature", selection: $temperature)

                HStack {
                    Text("Only this provider/model is changed. API keys stay in Keychain.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.sm)
                    Button("Reset") { reset() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                }
            }
            .padding(.top, Spacing.xs)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
        .accessibilityHint("Set context, output, and feature support for \(profile.model).")
    }

    private var effectiveSummary: String {
        var parts: [String] = []
        if let context = effectiveProfile.contextWindow { parts.append("context \(context.formatted())") }
        if let output = effectiveProfile.maxOutputTokens { parts.append("output \(output.formatted())") }
        if effectiveProfile.supportsTools == true { parts.append("tools") }
        if !effectiveProfile.effectiveReasoningEfforts.isEmpty { parts.append("reasoning") }
        if effectiveProfile.supportsVision == true { parts.append("vision") }
        if effectiveProfile.supportsTemperature == true { parts.append("temperature") }
        return parts.isEmpty ? "Effective metadata is unknown — use the controls below for this gateway." : parts.joined(separator: " · ")
    }

    private func capabilityPicker(_ title: String, selection: Binding<CapabilityMode>) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(CapabilityMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func save() {
        let override = RemoteModelOverride(
            contextWindow: positiveInt(contextWindow),
            maxOutputTokens: positiveInt(outputTokens),
            supportsVision: vision.value,
            supportsTools: tools.value,
            supportsReasoning: reasoning.value,
            supportsTemperature: temperature.value,
            reasoningEffort: reasoningEffort)
        AppPreferencesStore.shared.saveRemoteModelOverride(override, endpoint: profile.endpoint())
    }

    private func reset() {
        contextWindow = ""
        outputTokens = ""
        vision = .automatic
        tools = .automatic
        reasoning = .automatic
        temperature = .automatic
        reasoningEffort = nil
        AppPreferencesStore.shared.saveRemoteModelOverride(nil, endpoint: profile.endpoint())
    }

    private func positiveInt(_ text: String) -> Int? {
        let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return value.flatMap { $0 > 0 ? $0 : nil }
    }
}
