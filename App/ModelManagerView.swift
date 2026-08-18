import SwiftUI

/// The Model Manager sheet. One scrolling column of cards: local catalog
/// models first, then remote (BYOK) providers. Each card surfaces the model's
/// identity, fit verdict and specs at a glance, with exactly one prominent
/// action and everything destructive tucked into an overflow menu.
struct ModelManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeaderView(
                freeBytes: appState.availableBudget,
                totalBytes: MemoryAdvisor.physicalMemory,
                onImport: importModel,
                onDone: { dismiss() })

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    LocalModelsSection()
                    RemoteSection()
                        .environmentObject(appState)
                }
                .padding(Spacing.lg)
            }
        }
        .background(Theme.bg)
    }

    /// Pick a local model directory and register it as a user-catalog model.
    private func importModel() {
        let panel = NSOpenPanel()
        panel.title = "Import MLX model folder"
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing config.json and .safetensors weight files."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path) else {
            presentImportError("No config.json found in the selected folder.")
            return
        }
        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        guard contents.contains(where: { $0.hasSuffix(".safetensors") }) else {
            presentImportError("No .safetensors weight files found in the selected folder.")
            return
        }
        if contents.contains(where: { $0.hasSuffix(".incomplete") }) {
            presentImportError("The folder contains incomplete downloads (.incomplete files). Finish the download first.")
            return
        }

        // Read model config for display metadata.
        var family = "Custom"
        var contextWindow = 32_768
        if let configData = try? Data(contentsOf: url.appendingPathComponent("config.json")),
           let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            family = (json["model_type"] as? String)?.capitalized ?? "Custom"
            contextWindow = (json["max_position_embeddings"] as? Int) ?? 32_768
        }

        let dirName = url.lastPathComponent
        let displayName = dirName.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let size = (try? ModelStore.sizeOfDirectory(url)) ?? 0

        let catalog = CatalogModel(
            id: dirName,
            repo: url.path,
            displayName: displayName,
            family: family,
            parameters: "—",
            quantization: "—",
            diskBytes: size,
            contextWindow: contextWindow,
            minRAMGB: max(6, Int(Double(size) / 1_000_000_000 * 1.5)),
            recommendedRAMGB: max(8, Int(Double(size) / 1_000_000_000 * 2)),
            notes: "Imported from \(url.path)")

        // Copy into the managed Models directory if it isn't already there.
        let dest = appState.modelStore.modelsBaseURL.appendingPathComponent(dirName, isDirectory: true)
        if !fm.fileExists(atPath: dest.path) {
            do {
                try fm.copyItem(at: url, to: dest)
            } catch {
                presentImportError("Copy failed: \(error.localizedDescription)")
                return
            }
        }

        // Save to user catalog so it persists across launches.
        var userModels = ModelCatalog.loadUserModels()
        userModels.removeAll { $0.id == catalog.id }
        userModels.append(catalog)
        ModelCatalog.saveUserModels(userModels)

        // Register as installed.
        _ = appState.modelStore.register(catalogModel: catalog, sizeBytes: size)
        appState.modelStore.objectWillChange.send()
    }

    private func presentImportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Import failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Header

/// Title row + a live RAM-budget gauge, so the user sees headroom at a
/// glance instead of parsing a caption.
private struct ManagerHeaderView: View {
    let freeBytes: UInt64
    let totalBytes: UInt64
    let onImport: () -> Void
    let onDone: () -> Void

    private var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, 1 - Double(freeBytes) / Double(totalBytes)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Models")
                    .font(.title2.bold())
                Spacer()
                Button("Import…", action: onImport)
                    .help("Import a local MLX model folder (must contain config.json + .safetensors)")
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Label("RAM budget", systemImage: "memorychip")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(ByteFormatter.bytes(freeBytes)) free of \(ByteFormatter.bytes(totalBytes))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceInset)
                        Capsule()
                            .fill(Theme.accentGradient)
                            .frame(width: max(4, proxy.size.width * usedFraction))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(Spacing.lg)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

// MARK: - Local models

private struct LocalModelsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: "On this Mac", systemImage: "cpu")
            ForEach(ModelCatalog.all) { model in
                ModelCard(model: model)
            }
        }
    }
}

/// Small uppercase section label with a glyph.
private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .textCase(.uppercase)
            .padding(.leading, Spacing.xs)
    }
}

// MARK: - Model card

private struct ModelCard: View {
    @EnvironmentObject private var appState: AppState
    let model: CatalogModel

    private var downloadState: ModelDownloadManager.State {
        appState.downloadManager.state(for: model.id)
    }

    private var budget: MemoryAdvisor.Budget { appState.budget(for: model) }

    private var isActive: Bool { appState.activeModelID == model.id }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ModelGlyph(format: model.format, isActive: isActive)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                titleRow
                sizeLine
                specChips
                if !model.notes.isEmpty {
                    Text(model.notes)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                if case .wontFit(let reason) = budget.verdict {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(3)
                }
                DownloadStatusView(state: downloadState)
            }

            Spacer(minLength: Spacing.sm)

            ModelActions(model: model, isActive: isActive, downloadState: downloadState, budget: budget)
        }
        .padding(Spacing.md)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(isActive ? Theme.washBorder(Theme.accent) : Theme.hairline,
                              lineWidth: isActive ? 1.5 : 1))
    }

    private var titleRow: some View {
        HStack(spacing: Spacing.sm) {
            Text(model.displayName)
                .font(.headline)
            Text(model.family)
                .font(.caption)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.wash(Theme.accent), in: Capsule())
            VerdictBadge(verdict: budget.verdict, projectedFootprint: budget.projectedFootprint)
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    /// Parameters · quantization · size. Installed rows use the measured
    /// on-disk size; the catalog estimate (~) only labels pending downloads.
    @ViewBuilder
    private var sizeLine: some View {
        if let installed = appState.modelStore.installedModel(id: model.id),
           appState.modelStore.isInstalled(catalogModel: model) {
            Text("\(model.parameters) · \(model.quantization) · \(ByteFormatter.bytes(installed.sizeBytes))")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        } else {
            Text(model.subtitle)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var specChips: some View {
        HStack(spacing: Spacing.xs) {
            SpecChip(text: "\(model.contextWindow / 1024)K context")
            SpecChip(text: "min \(model.minRAMGB) GB")
            SpecChip(text: "rec \(model.recommendedRAMGB) GB")
        }
    }
}

/// Leading icon tile for a model card.
private struct ModelGlyph: View {
    let format: CatalogModel.Format
    let isActive: Bool

    var body: some View {
        Image(systemName: format == .gguf ? "shippingbox" : "cpu")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
            .frame(width: 38, height: 38)
            .background(isActive ? Theme.accentSoft : Theme.surfaceInset,
                        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

/// Tiny capsule for one spec (context window, RAM floors).
private struct SpecChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surfaceInset, in: Capsule())
    }
}

/// Fit verdict as a tinted capsule so it scans like a status light.
private struct VerdictBadge: View {
    let verdict: MemoryAdvisor.Verdict
    let projectedFootprint: UInt64

    var body: some View {
        let (label, icon, tint): (String, String, Color) = {
            switch verdict {
            case .fits:     return ("Fits", "checkmark.circle.fill", Theme.success)
            case .marginal: return ("Marginal", "exclamationmark.triangle.fill", Theme.warning)
            case .wontFit:  return ("Won't fit", "xmark.octagon.fill", Theme.danger)
            }
        }()
        return Label(label, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.wash(tint), in: Capsule())
            .help("Projected peak: \(ByteFormatter.bytes(projectedFootprint))")
    }
}

/// Download lifecycle status under the card text — preparing spinner,
/// progress bar, paused note or failure message.
private struct DownloadStatusView: View {
    let state: ModelDownloadManager.State

    var body: some View {
        switch state {
        case .preparing:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Contacting Hugging Face…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress.fraction)
                    .tint(Theme.accent)
                    .frame(maxWidth: 320)
                Text("\(ByteFormatter.bytes(progress.completedBytes)) of \(ByteFormatter.bytes(progress.totalBytes)) — \(progress.currentFile)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .paused(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress.fraction)
                    .tint(Theme.warning)
                    .frame(maxWidth: 320)
                Text("Paused at \(ByteFormatter.bytes(progress.completedBytes)) — resumes from here")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }
}

// MARK: - Card actions

/// Exactly one prominent action plus an overflow menu for destructive or
/// secondary commands, so the card never shows a jagged stack of buttons.
private struct ModelActions: View {
    @EnvironmentObject private var appState: AppState
    let model: CatalogModel
    let isActive: Bool
    let downloadState: ModelDownloadManager.State
    let budget: MemoryAdvisor.Budget

    private var isInstalled: Bool {
        appState.modelStore.isInstalled(catalogModel: model)
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            primaryAction
            overflowMenu
        }
        // One button voice across every card: caption, medium weight.
        .font(.caption.weight(.medium))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if isInstalled {
            if isActive {
                Button("Unload") {
                    Task { await appState.deactivate() }
                }
                .buttonStyle(.bordered)
            } else {
                Button("Load") {
                    Task { await appState.activate(model: model) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(budget.verdict.fitsLoad == false)
            }
        } else {
            switch downloadState {
            case .preparing, .downloading:
                Button("Pause") {
                    appState.pauseDownload(of: model)
                }
                .buttonStyle(.bordered)
            case .paused:
                Button("Resume") {
                    appState.startDownload(of: model)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            case .failed:
                Button("Retry") {
                    appState.startDownload(of: model)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            case .completed:
                ProgressView().controlSize(.small)
            case .idle:
                // RAM gates LOADING, not downloading: the user may be
                // storing the model for later or for another machine.
                Button("Download") {
                    appState.startDownload(of: model)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .help("Resumable download with integrity checks")
            }
        }
    }

    @ViewBuilder
    private var overflowMenu: some View {
        if isInstalled {
            Menu {
                Button("Remove…", role: .destructive, action: removeInstalled)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        } else {
            switch downloadState {
            case .preparing, .downloading, .paused:
                Menu {
                    Button("Cancel Download", role: .destructive) {
                        appState.cancelDownload(of: model)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            default:
                EmptyView()
            }
        }
    }

    private func removeInstalled() {
        guard let installed = appState.modelStore.installedModel(id: model.id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(model.displayName)?"
        alert.informativeText = "Deletes \(ByteFormatter.bytes(installed.sizeBytes)) from disk. You can download it again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if appState.activeModelID == model.id {
                Task {
                    await appState.deactivate()
                    appState.modelStore.uninstall(installed)
                }
            } else {
                appState.modelStore.uninstall(installed)
            }
        }
    }
}

// MARK: - Remote (BYOK)

/// BYOK remote providers — activate one to run the agent without a local
/// model download. Rendered as a proper legible panel: a real header row,
/// full-size provider rows, and a bounded scroll region so many configured
/// providers never push the sheet off-screen or clip their own text.
private struct RemoteSection: View {
    @EnvironmentObject private var appState: AppState

    private var configured: [LLMProvider] {
        APIKeyStore.shared.configuredProviders.sorted {
            $0.displayName < $1.displayName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: "Remote (BYOK)", systemImage: "cloud")

            VStack(alignment: .leading, spacing: Spacing.sm) {
                if configured.isEmpty {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "key")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(Theme.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No providers configured")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Add an API key in Settings → Providers to run the agent on a remote model.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: Spacing.xs) {
                            ForEach(configured) { provider in
                                providerRow(provider)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            .padding(Spacing.md)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private func providerRow(_ provider: LLMProvider) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(modelID(for: provider))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Spacing.md)
            if appState.isRemoteActive,
               appState.engine.activeRemoteEndpoint?.provider == provider {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
                Button("Use local") {
                    appState.deactivateRemote()
                }
                .buttonStyle(.bordered)
            } else {
                // Same rule as the model cards: the forward action is the
                // single prominent button, tinted with the accent.
                Button("Use remote") {
                    let endpoint = RemoteEndpoint(
                        provider: provider,
                        model: modelID(for: provider))
                    Task {
                        _ = await appState.activateRemote(endpoint: endpoint)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    private func modelID(for provider: LLMProvider) -> String {
        AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
            ?? provider.defaultModel
    }
}
