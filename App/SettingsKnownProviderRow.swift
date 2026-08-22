import AppKit
import SwiftUI

struct KnownProviderRow: View {
    let provider: KnownRemoteProvider
    @ObservedObject private var keyStore = APIKeyStore.shared
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var reasoningEffort: String?
    @State private var liveProfiles: [RemoteModelProfile] = []
    @State private var state: ProviderRowState = .idle

    private enum ProviderRowState: Equatable {
        case idle
        case running(String)
        case success(String)
        case failure(String)
    }

    private var configured: Bool { keyStore.hasKey(forProviderID: provider.id) }

    private var resolvedKey: String {
        let draft = CredentialNormalizer.normalize(keyDraft)
        return draft.isEmpty ? (keyStore.key(forProviderID: provider.id) ?? "") : draft
    }

    private var selectedModel: String {
        let value = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.defaultModel : value
    }

    private var modelChoices: [String] {
        var seen = Set<String>()
        return (liveProfiles.map(\.model) + provider.availableModels)
            .filter { !seen.insert($0).inserted ? false : true }
    }

    private var selectedProfile: RemoteModelProfile {
        let cached = liveProfiles.first(where: { $0.model == selectedModel })
            ?? AppPreferencesStore.shared.current.remoteModelProfiles.values.first(where: {
                $0.providerKey == provider.id && $0.model == selectedModel
            })
        let base = cached ?? RemoteModelProfile(
            provider: .custom,
            model: selectedModel,
            supportsTools: true,
            providerKey: provider.id,
            providerDisplayName: provider.displayName,
            apiProtocol: provider.apiProtocol,
            baseURL: provider.baseURL.absoluteString)
        return base.applying(
            AppPreferencesStore.shared.remoteModelOverride(endpoint: base.endpoint()))
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
                    Text("OpenAI-compatible · \(provider.id)")
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

            Text(provider.baseURL.absoluteString)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: Spacing.sm) {
                SecureField(configured ? "API key (replace)" : "API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test") { test() }
                    .buttonStyle(.bordered)
                    .disabled(resolvedKey.isEmpty || isRunning)
                Button("Refresh") { refreshModels() }
                    .buttonStyle(.bordered)
                    .disabled(resolvedKey.isEmpty || isRunning)
            }

            HStack(spacing: Spacing.sm) {
                TextField("Model id", text: $modelDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { persistModel() }
                if !modelChoices.isEmpty {
                    Menu {
                        ForEach(modelChoices, id: \.self) { model in
                            Button {
                                modelDraft = model
                                persistModel()
                            } label: {
                                Text(model)
                            }
                        }
                    } label: {
                        Label("Models", systemImage: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.bordered)
                }
            }

            ReasoningEffortPicker(profile: selectedProfile, selection: $reasoningEffort)
                .id(selectedProfile.id)
                .onChange(of: reasoningEffort) { _, _ in persistReasoningEffort() }

            switch state {
            case .idle: EmptyView()
            case .running(let message):
                Label(message, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            case .failure(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(.vertical, Spacing.sm)
        .task {
            restoreModel()
            loadReasoningEffort()
        }
        .onChange(of: modelDraft) { _, _ in loadReasoningEffort() }
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private func restoreModel() {
        if let saved = AppPreferencesStore.shared.current.remoteModelProfiles.values.first(where: {
            $0.providerKey == provider.id
        }) {
            modelDraft = saved.model
            liveProfiles = [saved]
        } else {
            modelDraft = provider.defaultModel
        }
    }

    private func save() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, keyStore.save(key: key, forProviderID: provider.id) else {
            state = .failure("Could not save this key to the Keychain.")
            return
        }
        keyDraft = ""
        persistModel()
        state = .success("Key saved securely.")
    }

    private func persistModel() {
        let model = selectedModel
        guard !model.isEmpty else { return }
        let profile = RemoteModelProfile(
            provider: .custom,
            model: model,
            supportsTools: true,
            providerKey: provider.id,
            providerDisplayName: provider.displayName,
            apiProtocol: provider.apiProtocol,
            baseURL: provider.baseURL.absoluteString)
        AppPreferencesStore.shared.saveRemoteModelProfiles([profile])
    }

    private func persistReasoningEffort() {
        var override = AppPreferencesStore.shared
            .remoteModelOverride(endpoint: selectedProfile.endpoint()) ?? RemoteModelOverride()
        override.reasoningEffort = reasoningEffort
        AppPreferencesStore.shared.saveRemoteModelOverride(
            override, endpoint: selectedProfile.endpoint())
    }

    private func loadReasoningEffort() {
        reasoningEffort = AppPreferencesStore.shared
            .remoteModelOverride(endpoint: selectedProfile.endpoint())?.reasoningEffort
    }

    private func test() {
        let key = resolvedKey
        guard !key.isEmpty else { return }
        state = .running("Testing \(selectedModel)…")
        Task {
            do {
                let answer = try await RemoteLLMClient.testConnection(
                    endpoint: provider.endpoint(model: selectedModel), apiKey: key)
                state = .success("Connected — \(answer)")
                persistModel()
            } catch {
                state = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func refreshModels() {
        let key = resolvedKey
        guard !key.isEmpty else { return }
        state = .running("Loading model list…")
        Task {
            do {
                let profiles = try await RemoteLLMClient.fetchModelProfiles(
                    endpoint: provider.endpoint(model: selectedModel), apiKey: key)
                liveProfiles = profiles
                AppPreferencesStore.shared.saveRemoteModelProfiles(profiles)
                if let first = profiles.first, modelDraft.isEmpty {
                    modelDraft = first.model
                }
                state = .success("Loaded \(profiles.count) models.")
            } catch {
                state = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}
