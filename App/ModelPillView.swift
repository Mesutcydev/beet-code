import SwiftUI

// MARK: - Composer model pill
//
// The composer's single source of model truth. Shows WHICH engine will run
// the next message — a loaded local model, an active BYOK provider, or a
// "Choose Model" affordance — and opens a designed popover that can switch
// it without leaving the composer. Every label derives from AppState; the
// pill never holds its own model string.

struct ModelSelectionPill: View {
    @EnvironmentObject private var appState: AppState
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: 6) {
                // A status dot before the icon: engine health is glanceable
                // even when the icon itself only says local vs remote.
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(iconColor)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            // Model identity is a text control in the command line, not a
            // competing badge. The status dot carries readiness at a glance.
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(minHeight: 26)
            .background(showPopover ? Theme.washStrong(Theme.accent) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottom) {
                if case .ready = appState.enginePhase {
                    Capsule()
                        .fill(borderColor)
                        .frame(width: 20, height: 2)
                }
            }
            .lfHoverLift()
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel("Active model: \(label)")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            ModelPickerPopover()
                .environmentObject(appState)
                .frame(width: 340)
        }
    }

    // MARK: Derived state — one canonical source (AppState/engine)

    private var label: String {
        switch appState.enginePhase {
        case .ready(let name):
            return name
        case .loading(let name):
            return "Loading \(name)…"
        case .failed:
            return "Choose Model"
        case .idle:
            return appState.activeModel != nil
                ? appState.activeModel!.displayName
                : "Choose Model"
        }
    }

    private var icon: String {
        if case .loading = appState.enginePhase { return "hourglass" }
        if case .failed = appState.enginePhase { return "exclamationmark.triangle" }
        return appState.isRemoteActive ? "cloud.fill" : "cpu.fill"
    }

    private var iconColor: Color {
        switch appState.enginePhase {
        case .ready: return Theme.success
        case .loading: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textSecondary
        }
    }

    private var statusColor: Color {
        switch appState.enginePhase {
        case .ready: return Theme.success
        case .loading: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textTertiary
        }
    }

    private var borderColor: Color {
        if showPopover { return Theme.washBorder(Theme.accent) }
        if case .ready = appState.enginePhase { return Theme.washBorder(Theme.accent) }
        return Theme.hairline
    }

    private var tooltip: String {
        switch appState.enginePhase {
        case .ready(let name): return "Active model: \(name). Click to switch."
        case .loading(let name): return "Loading \(name)…"
        case .failed: return "No usable model. Click to pick one."
        case .idle: return "No model loaded. Click to pick one."
        }
    }
}

// MARK: - Picker popover

/// Designed popup: installed local models first (Load / active), then
/// configured BYOK providers, then management entries. Selecting anything
/// here performs the real switch — no decorative rows.
private struct ModelPickerPopover: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var keyStore = APIKeyStore.shared
    private enum Source: String, CaseIterable, Identifiable {
        case local, api
        var id: String { rawValue }
        var label: String { self == .local ? "Local models" : "API models" }
    }
    @State private var source: Source = .local

    private var installedModels: [CatalogModel] {
        // Chat models only — vision sidecars are never loadable here; the
        // app runs them automatically for image attachments.
        ModelCatalog.all.filter {
            $0.role == .chat && appState.modelStore.isInstalled(catalogModel: $0)
        }
    }

    private var remoteProviders: [LLMProvider] {
        APIKeyStore.shared.configuredProviders.sorted { $0.displayName < $1.displayName }
    }

    private var remoteModels: [RemoteModelProfile] {
        let configured = Set(remoteProviders)
        var profiles = AppPreferencesStore.shared.current.remoteModelProfiles.values
            .filter { profile in
                if configured.contains(profile.provider) { return true }
                guard let providerKey = profile.providerKey else { return false }
                return keyStore.hasKey(forProviderID: providerKey)
            }
        for provider in remoteProviders {
            guard !profiles.contains(where: { $0.provider == provider }) else { continue }
            let model = AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
                ?? provider.defaultModel
            guard !model.isEmpty else { continue }
            profiles.append(RemoteModelProfile(
                provider: provider, model: model,
                supportsVision: provider.supportsVision, supportsTools: true))
        }
        // OpenCode project/global configs are first-class API model sources.
        // Keep their provider id and protocol on the profile so selecting a
        // row cannot accidentally route the same model name through another
        // provider's chat endpoint.
        for model in appState.openCodeCatalog.models {
            let profile = model.remoteProfile()
            if !profiles.contains(where: { $0.id == profile.id }) {
                profiles.append(profile)
            }
        }
        // Named compatible gateways use the same dynamic endpoint identity as
        // imported OpenCode providers, but are also available when no
        // opencode.json file exists.
        for provider in KnownRemoteProvider.all where keyStore.hasKey(forProviderID: provider.id) {
            guard !profiles.contains(where: { $0.providerKey == provider.id }) else { continue }
            profiles.append(RemoteModelProfile(
                provider: .custom,
                model: provider.defaultModel,
                supportsTools: true,
                providerKey: provider.id,
                providerDisplayName: provider.displayName,
                apiProtocol: provider.apiProtocol,
                baseURL: provider.baseURL.absoluteString))
        }
        return profiles.sorted {
            if $0.displayProviderName != $1.displayProviderName {
                return $0.displayProviderName < $1.displayProviderName
            }
            return $0.model.localizedStandardCompare($1.model) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Model source", selection: $source) {
                        ForEach(Source.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.bottom, 2)
                    if source == .local {
                        localSection
                    } else {
                        apiSection
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        // Opaque themed surface — a material popover would stay neutral
        // gray in Beet mode while everything around it goes plum.
        .background(Theme.surface)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu.fill")
                .foregroundStyle(Theme.accent)
            Text(source == .local ? "Local model" : "API model")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            switch appState.enginePhase {
            case .ready:
                statusBadge("Ready", color: Theme.success, icon: "checkmark.circle.fill")
            case .loading:
                statusBadge("Loading…", color: Theme.warning, icon: "hourglass")
            case .failed:
                statusBadge("Failed", color: Theme.danger, icon: "exclamationmark.triangle.fill")
            case .idle:
                statusBadge("Idle", color: Theme.textSecondary, icon: "circle")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func statusBadge(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.wash(color)))
    }

    // MARK: Local models

    @ViewBuilder
    private var localSection: some View {
        sectionLabel("On this Mac")
        if installedModels.isEmpty {
            Text("No local models yet — download one in the Model Manager.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 2)
        } else {
            ForEach(installedModels) { model in
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: CatalogModel) -> some View {
        let isActive = appState.activeModelID == model.id
        let loadingThis = appState.enginePhase == .loading(model.displayName)
        let budget = appState.budget(for: model)
        return Button {
            dismiss()
            Task { await appState.activate(model: model) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "cpu")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.success : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(model.parameters) · \(model.quantization) · \(budgetHint(budget))")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if loadingThis {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Text("Active")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.success)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(isActive ? Theme.accentSoft : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(loadingThis)
        .help(budget.helpText)
    }

    private func budgetHint(_ budget: MemoryAdvisor.Budget) -> String {
        switch budget.verdict {
        case .fits: return "fits in RAM"
        case .marginal: return "tight fit"
        case .wontFit: return "won't fit"
        }
    }

    // MARK: API models

    @ViewBuilder
    private var apiSection: some View {
        sectionLabel("Configured API models")
        if remoteModels.isEmpty {
            HStack(spacing: 6) {
                Text("No API models configured yet.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Add provider…") {
                    dismiss()
                    // The Settings scene can't be opened via Notification —
                    // use the system action that raises it.
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 2)
        } else {
            ForEach(remoteModels) { profile in
                apiModelRow(profile)
            }
        }
    }

    private func apiModelRow(_ profile: RemoteModelProfile) -> some View {
        let provider = profile.provider
        let activeEndpoint = appState.engine.activeRemoteEndpoint
        let isActive = appState.isRemoteActive
            && activeEndpoint?.provider == provider
            && activeEndpoint?.providerID == profile.providerKey
            && activeEndpoint?.model == profile.model
        return Button {
            dismiss()
            Task {
                _ = await appState.activateRemote(endpoint: profile.endpoint())
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "cloud")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.success : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName ?? profile.model)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(profile.displayProviderName) · \(profile.model)")
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isActive {
                    Text("Active")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.success)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(isActive ? Theme.accentSoft : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Use \(provider.displayName) / \(profile.model)")
    }

    // MARK: Footer actions

    private var footer: some View {
        HStack(spacing: 10) {
            if appState.activeModelID != nil || appState.isRemoteActive {
                Button {
                    dismiss()
                    Task { await appState.deactivate() }
                } label: {
                    Label("Unload", systemImage: "eject")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Unload the current model and free its memory")
            }
            Spacer()
            Button {
                dismiss()
                NotificationCenter.default.post(name: .openModelManager, object: nil)
            } label: {
                    Label(source == .local ? "Model Manager…" : "Manage API models…",
                          systemImage: source == .local ? "square.and.arrow.down.on.square" : "key")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .help("Download more models, import folders, manage providers")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 4)
    }
}

// MARK: - Budget help text

private extension MemoryAdvisor.Budget {
    var helpText: String {
        "Projected peak memory: \(ByteFormatter.bytes(projectedFootprint))"
    }
}
