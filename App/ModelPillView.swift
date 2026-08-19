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
            // The row's one identity control: primary text, and an accent
            // border once an engine is actually ready — before that it wears
            // the same hairline as the accessory pills.
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .background(Theme.surfaceInset, in: Capsule())
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    localSection
                    remoteSection
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu.fill")
                .foregroundStyle(Theme.accent)
            Text("Model")
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

    // MARK: Remote providers

    @ViewBuilder
    private var remoteSection: some View {
        sectionLabel("Remote (BYOK)")
        if remoteProviders.isEmpty {
            HStack(spacing: 6) {
                Text("No providers configured.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Add key…") {
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
            ForEach(remoteProviders) { provider in
                providerRow(provider)
            }
        }
    }

    private func providerRow(_ provider: LLMProvider) -> some View {
        let isActive = appState.isRemoteActive
            && appState.engine.activeRemoteEndpoint?.provider == provider
        let modelID = AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
            ?? provider.defaultModel
        return Button {
            dismiss()
            Task {
                _ = await appState.activateRemote(endpoint: RemoteEndpoint(
                    provider: provider, model: modelID))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "cloud")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.success : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(modelID)
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
                Label("Model Manager…", systemImage: "square.and.arrow.down.on.square")
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
