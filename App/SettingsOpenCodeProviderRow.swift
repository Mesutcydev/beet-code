import AppKit
import SwiftUI

struct OpenCodeProviderRow: View {
    let provider: OpenCodeCompatibility.ProviderProfile
    @ObservedObject private var keyStore = APIKeyStore.shared
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    private enum TestState: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }
    @State private var testState: TestState = .idle

    private var selectedModelID: String {
        let value = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (provider.models.first?.modelID ?? "") : value
    }

    private var selectedModel: OpenCodeCompatibility.ModelProfile? {
        provider.models.first { $0.modelID == selectedModelID }
    }

    private var selectedProfile: RemoteModelProfile? {
        guard !selectedModelID.isEmpty else { return nil }
        if let selectedModel { return selectedModel.remoteProfile() }
        return RemoteModelProfile(
            provider: LLMProvider.fromOpenCodeIdentifier(provider.id) ?? .custom,
            model: selectedModelID,
            supportsTools: true,
            providerKey: provider.id,
            providerDisplayName: provider.displayName,
            apiProtocol: provider.apiProtocol,
            baseURL: provider.baseURL?.absoluteString,
            headers: provider.headers,
            apiKey: provider.apiKey)
    }

    private var configured: Bool {
        provider.apiKey?.isEmpty == false || keyStore.hasKey(forProviderID: provider.id)
    }
    private var resolvedKey: String {
        let draft = CredentialNormalizer.normalize(keyDraft)
        if !draft.isEmpty { return draft }
        return keyStore.key(forProviderID: provider.id) ?? provider.apiKey ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(provider.id) · \(provider.apiProtocol.label)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if configured {
                    Label("Configured", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.success)
                }
            }
            if let baseURL = provider.baseURL {
                Text(baseURL.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if !provider.models.isEmpty {
                    Picker("Model", selection: $modelDraft) {
                        ForEach(provider.models) { model in
                            Text(model.title).tag(model.modelID)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: modelDraft) { _, _ in persistSelectedModel() }
                }
                TextField("Model id", text: $modelDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { persistSelectedModel() }
                if let profile = selectedProfile {
                    Text(profileSummary(profile))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    RemoteModelCapabilityEditor(profile: profile)
                        .id(profile.id)
                } else {
                    Text("Add a model id to make this OpenCode provider available in the composer.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(spacing: Spacing.sm) {
                SecureField(configured ? "API key (replace)" : "API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Save") {
                    guard !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    _ = keyStore.save(key: keyDraft, forProviderID: provider.id)
                    keyDraft = ""
                    testState = .idle
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Button("Test") { test() }
                    .buttonStyle(.bordered)
                    .disabled(selectedProfile == nil || testState == .running || resolvedKey.isEmpty)
            }
            switch testState {
            case .idle: EmptyView()
            case .running:
                Label("Contacting provider…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            case .ok(let detail):
                Label(detail, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            case .failed(let detail):
                Label(detail, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(.vertical, Spacing.sm)
        .onAppear {
            if modelDraft.isEmpty { modelDraft = provider.models.first?.modelID ?? "" }
            persistSelectedModel()
        }
    }

    private func test() {
        guard let profile = selectedProfile else { return }
        testState = .running
        var endpoint = profile.endpoint()
        endpoint.apiKey = resolvedKey
        Task {
            do {
                let answered = try await RemoteLLMClient.testConnection(endpoint: endpoint, apiKey: resolvedKey)
                testState = .ok("Connected — \(answered)")
            } catch {
                testState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func persistSelectedModel() {
        guard let profile = selectedProfile else { return }
        AppPreferencesStore.shared.saveRemoteModelProfiles([profile])
    }

    private func profileSummary(_ profile: RemoteModelProfile) -> String {
        var parts: [String] = []
        if let context = profile.contextWindow { parts.append("context \(context.formatted())") }
        if let output = profile.maxOutputTokens { parts.append("output \(output.formatted())") }
        if profile.supportsTools == true { parts.append("tools") }
        if profile.supportsReasoning == true { parts.append("reasoning") }
        if profile.supportsVision == true { parts.append("vision") }
        return parts.isEmpty ? "Model metadata is unknown — set capability overrides for this gateway." : parts.joined(separator: " · ")
    }
}

/// One provider card: key input, model choice, save/test/remove actions and
/// the exact endpoint it talks to — so misconfigured providers (wrong key
