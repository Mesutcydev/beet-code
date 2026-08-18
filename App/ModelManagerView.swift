import SwiftUI

struct ModelManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(ModelCatalog.all) { model in
                ModelRow(model: model)
            }
            .listStyle(.inset)
        }
        .background(.ultraThinMaterial)
        .safeAreaInset(edge: .bottom) {
            RemoteSection()
                .environmentObject(appState)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
        }
        .onChange(of: appState.downloadManager.states) { _, _ in
            // Completion is handled reactively in ModelRow via onChange.
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models").font(.title2.bold())
                Text("RAM budget: \(ByteFormatter.bytes(appState.availableBudget)) free of \(ByteFormatter.bytes(MemoryAdvisor.physicalMemory)) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import…") { importModel() }
                .help("Import a local MLX model folder (must contain config.json + .safetensors)")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
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

private struct ModelRow: View {
    @EnvironmentObject private var appState: AppState
    let model: CatalogModel

    private var downloadState: ModelDownloadManager.State {
        appState.downloadManager.state(for: model.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.displayName).font(.headline)
                    Text(model.family).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    verdictBadge
                    if isActive { Label("Active", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.success) }
                }
                Text(model.subtitle).font(.callout).foregroundStyle(.secondary)
                Text("\(model.contextWindow / 1024)K context · min \(model.minRAMGB) GB RAM · recommends \(model.recommendedRAMGB) GB")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !model.notes.isEmpty {
                    Text(model.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if case .wontFit(let reason) = budget.verdict {
                    Text(reason).font(.caption).foregroundStyle(Theme.danger).lineLimit(3)
                }
                downloadProgressView
            }
            Spacer()
            actions
        }
        .padding(.vertical, 6)
        // Download completion is handled by AppState (idempotent even when
        // this sheet is closed); rows only render state.
    }

    private var budget: MemoryAdvisor.Budget { appState.budget(for: model) }

    private var isActive: Bool { appState.activeModelID == model.id }

    @ViewBuilder
    private var downloadProgressView: some View {
        switch downloadState {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Contacting Hugging Face…").font(.caption).foregroundStyle(.secondary)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 320)
                Text("\(ByteFormatter.bytes(progress.completedBytes)) of \(ByteFormatter.bytes(progress.totalBytes)) — \(progress.currentFile)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .paused(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 320)
                Text("Paused at \(ByteFormatter.bytes(progress.completedBytes)) — resumes from here")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
        default:
            EmptyView()
        }
    }

    private var verdictBadge: some View {
        Group {
            switch budget.verdict {
            case .fits:
                Label("Fits", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            case .marginal:
                Label("Marginal", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            case .wontFit:
                Label("Won't fit", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Theme.danger)
            }
        }
        .font(.caption)
        .help("Projected peak: \(ByteFormatter.bytes(budget.projectedFootprint))")
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if appState.modelStore.isInstalled(catalogModel: model) {
                if isActive {
                    Button("Unload") {
                        Task { await appState.deactivate() }
                    }
                } else {
                    Button("Load") {
                        Task { await appState.activate(model: model) }
                    }
                    .disabled(budget.verdict.fitsLoad == false)
                }
                Button("Remove…", role: .destructive) {
                    removeInstalled()
                }
                .font(.caption)
            } else {
                switch downloadState {
                case .preparing, .downloading:
                    Button("Pause") {
                        appState.pauseDownload(of: model)
                    }
                    Button("Cancel", role: .destructive) {
                        appState.cancelDownload(of: model)
                    }
                    .font(.caption)
                case .paused:
                    Button("Resume") {
                        appState.startDownload(of: model)
                    }
                    Button("Cancel", role: .destructive) {
                        appState.cancelDownload(of: model)
                    }
                    .font(.caption)
                case .failed:
                    Button("Retry") {
                        appState.startDownload(of: model)
                    }
                case .completed:
                    ProgressView().controlSize(.small)
                case .idle:
                    // RAM gates LOADING, not downloading: the user may be
                    // storing the model for later or for another machine.
                    Button("Download") {
                        appState.startDownload(of: model)
                    }
                    .help("Resumable download with integrity checks")
                }
            }
        }
        .buttonStyle(.bordered)
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
/// BYOK remote providers — activate one to run the agent without a local
/// model download.
private struct RemoteSection: View {
    @EnvironmentObject private var appState: AppState

    private var configured: [LLMProvider] {
        LLMProvider.allCases.filter { APIKeyStore.shared.key(for: $0) != nil }
    }

    var body: some View {
        Section("Remote (BYOK)") {
            if configured.isEmpty {
                Text("Add an API key in Settings → BYOK Providers to run the agent on a remote model.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(configured) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName).font(.callout)
                            Text(modelID(for: provider))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.isRemoteActive,
                           appState.engine.activeRemoteEndpoint?.provider == provider {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.success)
                            Button("Use local") {
                                appState.deactivateRemote()
                            }
                            .font(.caption)
                        } else {
                            Button("Use remote") {
                                let endpoint = RemoteEndpoint(
                                    provider: provider,
                                    model: modelID(for: provider))
                                Task {
                                    _ = await appState.activateRemote(endpoint: endpoint)
                                }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func modelID(for provider: LLMProvider) -> String {
        AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
            ?? provider.defaultModel
    }
}