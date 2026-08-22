import AppKit
import SwiftUI

struct ProviderCard: View {
    let provider: LLMProvider
    @ObservedObject private var keyStore = APIKeyStore.shared
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var baseURDraft = ""
    /// Models fetched live from the provider (P10); merged into the picker.
    @State private var liveModels: [String] = []
    @State private var liveProfiles: [RemoteModelProfile] = []
    @State private var refreshingModels = false
    @State private var modelListError: String?
    @State private var overrideContextWindow = ""
    @State private var overrideOutputTokens = ""
    @State private var overrideVision: CapabilityMode = .automatic
    @State private var overrideTools: CapabilityMode = .automatic
    @State private var overrideReasoning: CapabilityMode = .automatic
    @State private var overrideReasoningEffort: String?
    @State private var overrideTemperature: CapabilityMode = .automatic

    enum TestState: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }
    @State private var testState: TestState = .idle
    @State private var saveMessage: String?

    private var hasKey: Bool { keyStore.hasKey(for: provider) }
    private var keyAvailableForUse: Bool {
        hasKey || !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var endpointLabel: String {
        provider.openAICompatibleBaseURL?.absoluteString
            ?? provider.geminiBaseURL?.absoluteString
            ?? provider.anthropicBaseURL?.absoluteString
            ?? "not configured — set a base URL below"
    }

    /// Custom + local servers run keyless (Ollama/LM Studio); the card must
    /// not gate everything behind an API key for them.
    private var keyless: Bool { provider.keyOptional && !hasKey }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header: provider glyph + name + status badges — the same
            // icon-header chrome every SettingsCard wears.
            HStack(spacing: Spacing.sm) {
                Image(systemName: provider == .custom ? "server.rack" : "cloud.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(provider.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if hasKey || (provider.keyOptional && provider.openAICompatibleBaseURL != nil) {
                    badge("Configured", systemImage: "checkmark.seal.fill", tint: Theme.success)
                }
                if provider.supportsVision {
                    badge("Vision", systemImage: "eye", tint: Theme.info)
                }
                Spacer()
                if hasKey {
                    Button("Remove key", role: .destructive) {
                        keyStore.deleteKey(for: provider)
                        keyDraft = ""
                        testState = .idle
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text(endpointLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Custom provider: base URL first — everything hangs off it.
            if provider == .custom {
                HStack(spacing: Spacing.sm) {
                    TextField("Base URL — e.g. http://127.0.0.1:11434/v1", text: $baseURDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                    Button("Save URL") {
                        var prefs = AppPreferencesStore.shared.current
                        prefs.customBaseURL = baseURDraft.trimmingCharacters(in: .whitespaces)
                        AppPreferencesStore.shared.save(prefs)
                        testState = .idle
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(baseURDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Works with any OpenAI-compatible server: Ollama, LM Studio, vLLM, llama.cpp, Groq, Together, corporate proxies. Key is optional for local servers.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            // Key input
            HStack(spacing: Spacing.sm) {
                SecureField(
                    hasKey ? "API key (replace)" : (keyless ? "API key (optional)" : "API key"),
                    text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Save") {
                    let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let keyForRefresh: String?
                    if !draft.isEmpty {
                        guard keyStore.save(key: draft, for: provider) else {
                            saveMessage = "Could not save this key to the Keychain. Try again or unlock Keychain access."
                            return
                        }
                        keyForRefresh = draft
                    } else {
                        keyForRefresh = resolvedKey.isEmpty ? nil : resolvedKey
                    }
                    if provider == .custom { persistBaseURLDraft() }
                    persistModelDraft()
                    keyDraft = ""
                    saveMessage = draft.isEmpty ? "Settings saved." : "API key saved securely."
                    testState = .idle
                    // Use the just-saved draft directly. A protected or
                    // migrated Keychain item must not make a valid new key
                    // disappear between Save and model discovery.
                    if let keyForRefresh { refreshModels(apiKey: keyForRefresh) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty && modelUnchanged && baseURUnchanged)
            }

            if let credentialHint = provider.credentialHint {
                Label(credentialHint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let saveMessage {
                Label(saveMessage, systemImage: saveMessage.hasPrefix("Could") ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(saveMessage.hasPrefix("Could") ? Theme.danger : Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Model choice — stacked: the picker gets its own full-width row,
            // the free-form model id + actions sit on the row below so
            // neither control fights for width.
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if !modelOptions.isEmpty {
                    SettingRow(label: "Model") {
                        Picker("Model", selection: $modelDraft) {
                            if !liveModels.isEmpty {
                                Section("Live from \(provider.displayName)") {
                                    ForEach(liveModels, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                Section("Common") {
                                    ForEach(provider.availableModels.filter { !liveModels.contains($0) }, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                            } else {
                                ForEach(modelOptions, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            if !modelDraft.isEmpty,
                               !liveModels.contains(modelDraft),
                               !provider.availableModels.contains(modelDraft) {
                                Section("Selected") {
                                    Text(modelDraft).tag(modelDraft)
                                }
                            }
                        }
                        .labelsHidden()
                    }
                }

                HStack(spacing: Spacing.sm) {
                    TextField("Model id", text: $modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())

                    Button {
                        refreshModels()
                    } label: {
                        if refreshingModels {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Fetch the provider's live model list")
                    .accessibilityLabel("Refresh \(provider.displayName) model list")
                    .disabled(refreshingModels || (!keyAvailableForUse && !provider.keyOptional))

                    Button("Test") { runTest() }
                        .buttonStyle(.bordered)
                        .disabled(testState == .running || (!keyAvailableForUse && !provider.keyOptional))
                }

                if !liveModels.isEmpty {
                    Text("Model list fetched live from \(provider.displayName) — \(liveModels.count) available.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                } else if hasKey || keyless {
                    Text("The list below is a static fallback — press ⟳ to fetch \(provider.displayName)'s current models.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                if let modelListError {
                    Label(modelListError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let profile = selectedProfile {
                    Text(profileSummary(profile))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                modelCapabilitiesEditor
            }

            // Test result — only rendered once a test is underway or done,
            // so an idle card stays compact (no reserved empty line).
            if testState != .idle {
                HStack(spacing: Spacing.xs) {
                    switch testState {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView().controlSize(.mini)
                        Text("Contacting \(provider.displayName)…")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    case .ok(let detail):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.success)
                            .lineLimit(3)
                    case .failed(let detail):
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(Theme.danger)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lfCard()
        .onAppear {
            modelDraft = AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
                ?? provider.defaultModel
            loadModelOverride()
            if provider == .custom {
                baseURDraft = AppPreferencesStore.shared.current.customBaseURL ?? ""
            }
            // Do not probe every provider's protected Keychain item on
            // settings launch. Refresh is explicit, or follows a Save.
        }
        .onChange(of: modelDraft) { _, _ in loadModelOverride() }
    }

    /// Status pill in the card header — washed fill + border from the tint
    /// so badges read identically to the rest of the app's tinted surfaces.
    private func badge(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.wash(tint), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.washBorder(tint), lineWidth: 1))
    }

    /// Suggested models, any saved draft, plus whatever the provider's live
    /// `/models` endpoint returned — static presets go stale fast (P10).
    private var modelOptions: [String] {
        var options = provider.availableModels
        for live in liveModels where !options.contains(live) {
            options.append(live)
        }
        if !modelDraft.isEmpty, !options.contains(modelDraft) {
            options.append(modelDraft)
        }
        return options
    }

    private var modelUnchanged: Bool {
        let saved = AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
            ?? provider.defaultModel
        return saved == modelDraft
    }

    private var baseURUnchanged: Bool {
        guard provider == .custom else { return true }
        return (AppPreferencesStore.shared.current.customBaseURL ?? "") == baseURDraft
    }

    private var resolvedKey: String {
        let draft = CredentialNormalizer.normalize(keyDraft)
        if !draft.isEmpty { return draft }
        return keyStore.key(for: provider) ?? ""
    }

    private func persistBaseURLDraft() {
        let trimmed = baseURDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var prefs = AppPreferencesStore.shared.current
        prefs.customBaseURL = trimmed
        AppPreferencesStore.shared.save(prefs)
    }

    private func persistModelDraft() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var preferences = AppPreferencesStore.shared.current
        preferences.remoteModel[provider.rawValue] = trimmed
        AppPreferencesStore.shared.save(preferences)
    }

    private func refreshModels(apiKey: String? = nil) {
        refreshingModels = true
        modelListError = nil
        let key = apiKey ?? (resolvedKey.isEmpty ? nil : resolvedKey)
        Task {
            do {
                let profiles = try await RemoteLLMClient.fetchModelProfiles(provider: provider, apiKey: key)
                await MainActor.run {
                    liveProfiles = profiles
                    liveModels = profiles.map(\.model)
                    AppPreferencesStore.shared.saveRemoteModelProfiles(profiles)
                    refreshingModels = false
                    if profiles.isEmpty {
                        modelListError = "The provider returned no usable models — type a model id manually or check its account access."
                    }
                }
            } catch {
                await MainActor.run {
                    // Keep the saved/manual model choices usable when a
                    // provider does not implement `/models` or blocks it for
                    // the account tier. Discovery is optional, credentials
                    // are not.
                    refreshingModels = false
                    let detail = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    modelListError = "Model discovery unavailable — you can still enter a model id manually. (\(detail))"
                }
            }
        }
    }

    private var selectedProfile: RemoteModelProfile? {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        let cached = liveProfiles.first(where: { $0.model == model })
            ?? AppPreferencesStore.shared.remoteModelProfile(provider: provider, model: model)
        let base = cached ?? RemoteModelProfile(
            provider: provider,
            model: model,
            supportsVision: provider.supportsVision,
            supportsTools: true,
            supportsTemperature: true)
        return base.applying(AppPreferencesStore.shared.remoteModelOverride(provider: provider, model: model))
    }

    private func profileSummary(_ profile: RemoteModelProfile) -> String {
        var parts: [String] = []
        if let context = profile.contextWindow { parts.append("context \(context.formatted())") }
        if let output = profile.maxOutputTokens { parts.append("output \(output.formatted())") }
        if profile.supportsTools == true { parts.append("tools") }
        if !profile.effectiveReasoningEfforts.isEmpty { parts.append("reasoning") }
        if profile.supportsVision == true { parts.append("vision") }
        return parts.isEmpty ? "Model metadata is unknown — use the capability overrides below for unusual gateways." : parts.joined(separator: " · ")
    }

    private var modelCapabilitiesEditor: some View {
        DisclosureGroup("Model capability overrides") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    TextField("Context window", text: $overrideContextWindow)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    TextField("Max output", text: $overrideOutputTokens)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                }
                capabilityPicker("Tools", selection: $overrideTools)
                capabilityPicker("Reasoning", selection: $overrideReasoning)
                if let profile = selectedProfile {
                    ReasoningEffortPicker(profile: profile, selection: $overrideReasoningEffort)
                        .id(profile.id)
                }
                capabilityPicker("Vision", selection: $overrideVision)
                capabilityPicker("Temperature", selection: $overrideTemperature)
                HStack {
                    Text("Overrides apply to this provider/model only and never store API keys.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Save overrides") { saveModelOverride() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.top, Spacing.xs)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
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

    private func loadModelOverride() {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = AppPreferencesStore.shared.remoteModelOverride(provider: provider, model: model)
        overrideContextWindow = override?.contextWindow.map(String.init) ?? ""
        overrideOutputTokens = override?.maxOutputTokens.map(String.init) ?? ""
        overrideVision = CapabilityMode(value: override?.supportsVision)
        overrideTools = CapabilityMode(value: override?.supportsTools)
        overrideReasoning = CapabilityMode(value: override?.supportsReasoning)
        overrideReasoningEffort = override?.reasoningEffort
        overrideTemperature = CapabilityMode(value: override?.supportsTemperature)
    }

    private func saveModelOverride() {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        let override = RemoteModelOverride(
            contextWindow: Int(overrideContextWindow.trimmingCharacters(in: .whitespacesAndNewlines)),
            maxOutputTokens: Int(overrideOutputTokens.trimmingCharacters(in: .whitespacesAndNewlines)),
            supportsVision: overrideVision.value,
            supportsTools: overrideTools.value,
            supportsReasoning: overrideReasoning.value,
            supportsTemperature: overrideTemperature.value,
            reasoningEffort: overrideReasoningEffort)
        AppPreferencesStore.shared.saveRemoteModelOverride(override, provider: provider, model: model)
    }

    private func runTest() {
        let key = resolvedKey
        guard !key.isEmpty || provider.keyOptional else {
            testState = .failed("No API key for \(provider.displayName) — paste one above first.")
            return
        }
        let model = modelDraft.trimmingCharacters(in: .whitespaces).isEmpty
            ? provider.defaultModel
            : modelDraft.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            testState = .failed("No model id configured for \(provider.displayName).")
            return
        }
        testState = .running
        Task {
            do {
                var endpoint = RemoteEndpoint(provider: provider, model: model)
                endpoint.apiKey = key
                let answered = try await RemoteLLMClient.testConnection(
                    endpoint: endpoint, apiKey: key)
                testState = .ok("Connected — answered as \(answered) (\(model))")
            } catch {
                // A valid credential can still be paired with a stale or
                // account-inaccessible model id. Probe the catalog once so
                // the UI distinguishes “key works” from “choose another
                // model” instead of rejecting both as an auth failure.
                if let remoteError = error as? RemoteLLMError,
                   case .badStatus(let code, _) = remoteError,
                   (400..<500).contains(code), !key.isEmpty {
                    if let profiles = try? await RemoteLLMClient.fetchModelProfiles(
                        provider: provider, apiKey: key), !profiles.isEmpty {
                        liveProfiles = profiles
                        liveModels = profiles.map(\.model)
                        AppPreferencesStore.shared.saveRemoteModelProfiles(profiles)
                        testState = .ok("Key accepted. \(model) is unavailable for this account; choose one of the \(profiles.count) available models.")
                        return
                    }
                }
                testState = .failed(testErrorMessage(error))
            }
        }
    }

    private func testErrorMessage(_ error: Error) -> String {
        let fallback = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        guard provider == .gemini,
              let remoteError = error as? RemoteLLMError,
              case .badStatus(let code, let detail) = remoteError,
              [400, 401, 403].contains(code),
              detail.localizedCaseInsensitiveContains("api key")
                || detail.localizedCaseInsensitiveContains("caller")
                || detail.localizedCaseInsensitiveContains("permission")
        else {
            return fallback
        }
        return "Google rejected this credential (HTTP \(code)). Create or copy a Gemini API key from Google AI Studio, or choose the provider that issued this key."
    }
}
