import Foundation

/// Registry of downloaded models on disk. Layout:
///   ~/Library/Application Support/BeetCode/Models/<model-id>/…
/// Each installed model records where it came from so updates and deletes
/// are exact.
struct InstalledModel: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var repo: String
    var addedAt: Date
    var sizeBytes: Int64
    /// Explicit base directory when the model lives OUTSIDE the managed
    /// Application Support Models folder (e.g. the project's gitignored
    /// `beetcode-models/` created by the legacy `lf download` CLI). nil means
    /// the default base.
    var basePath: String?

    var directoryName: String { id }
}

@MainActor
final class ModelStore: ObservableObject {

    static let shared = ModelStore()

    @Published private(set) var installed: [InstalledModel] = []

    private let fileManager = FileManager.default

    /// Test seam: redirects the models directory away from real Application
    /// Support.
    var overrideModelsDir: URL?

    /// Base directory for all model snapshots (Application Support/BeetCode/Models).
    var modelsBaseURL: URL {
        modelsDirectory
    }

    private var modelsDirectory: URL {
        if let override = overrideModelsDir { return override }
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeetCode/Models", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Extra scan roots: the legacy CLI (`lf download`) stored weights in the
    /// repo checkout (`beetcode-models/`, `localforge-models/`) instead of
    /// Application Support. #file resolves this source file's location at
    /// compile time, so the project-relative folder is found regardless of
    /// the app's launch working directory. Downloads/imports still target
    /// the managed Application Support folder only.
    nonisolated static var extraScanDirectories: [URL] {
        let sourceDir = URL(fileURLWithPath: #filePath)  // Core/ModelManager
        let projectRoot = sourceDir.deletingLastPathComponent().deletingLastPathComponent()
        return [
            projectRoot.appendingPathComponent("beetcode-models", isDirectory: true),
            projectRoot.appendingPathComponent("localforge-models", isDirectory: true),
        ]
    }

    private var registryURL: URL {
        modelsDirectory.appendingPathComponent("InstalledModels.json")
    }

    init() {
        loadRegistry()
        // Repair: drop registry entries whose directories vanished (moved or
        // deleted outside the app).
        let before = installed.count
        installed.removeAll { model in
            !fileManager.fileExists(atPath: directory(for: model).path)
                || !self.hasConfiguration(model)
        }
        if installed.count != before {
            saveRegistry()
        }
        // Registry missing but model directories present (manual copy, older
        // version, or the legacy CLI's repo-relative folder): rescan off the
        // main actor — sizing multi-gigabyte model directories must never
        // block the UI.
        if installed.isEmpty, hasModelDirectories() {
            let base = modelsBaseURL
            let extras = Self.extraScanDirectories
            Task.detached(priority: .utility) {
                var scanned = Self.scanFromDisk(modelsDirectory: base)
                for extra in extras {
                    scanned.append(contentsOf: Self.scanFromDisk(modelsDirectory: extra))
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.installed = scanned
                    self.saveRegistry()
                }
            }
        }
    }

    private func hasModelDirectories() -> Bool {
        let roots = [modelsDirectory] + Self.extraScanDirectories
        let catalogIDs = Set(ModelCatalog.all.map(\.id))
        return roots.contains { root in
            let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
            return names.contains { catalogIDs.contains($0) }
        }
    }

    func directory(for model: InstalledModel) -> URL {
        if let basePath = model.basePath {
            return URL(fileURLWithPath: basePath, isDirectory: true)
                .appendingPathComponent(model.directoryName, isDirectory: true)
        }
        return modelsDirectory.appendingPathComponent(model.directoryName, isDirectory: true)
    }

    /// A downloaded model is loadable when its weight files are complete.
    /// Two layouts:
    /// - **MLX**: `config.json` + ≥1 `.safetensors` (the historical layout)
    /// - **GGUF**: ≥1 `.gguf` file (llama.cpp; no config.json in the repo)
    /// A leftover `.incomplete` file always means the download never finished.
    func hasConfiguration(_ model: InstalledModel) -> Bool {
        let dir = directory(for: model)
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return Self.isCompleteSnapshot(dirNames: names)
    }

    /// Shared completeness check for `hasConfiguration` and `scanFromDisk` —
    /// the two must agree or a model shows as installed in one place and as
    /// "Download" in another.
    nonisolated static func isCompleteSnapshot(dirNames names: [String]) -> Bool {
        if names.contains(where: { $0.hasSuffix(".incomplete") }) {
            return false
        }
        // GGUF first: a single-file format, complete iff the .gguf exists.
        if names.contains(where: { $0.lowercased().hasSuffix(".gguf") }) {
            return true
        }
        // MLX: config.json plus real weight files (a directory holding only
        // config/tokenizer files — interrupted before the weights arrived —
        // would otherwise crash the loader with `keyNotFound(lm_head.weight)`).
        guard names.contains("config.json") else { return false }
        return names.contains(where: {
            $0.hasSuffix(".safetensors") || $0.hasSuffix(".weight")
        })
    }

    /// Detects the weights format present on disk for an installed model.
    /// GGUF directories carry a `.gguf` file; everything else is MLX.
    func detectedFormat(_ model: InstalledModel) -> CatalogModel.Format {
        let dir = directory(for: model)
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            return .mlx
        }
        if names.contains(where: { $0.lowercased().hasSuffix(".gguf") }) {
            return .gguf
        }
        return .mlx
    }

    func isInstalled(catalogModel: CatalogModel) -> Bool {
        installed.contains { $0.id == catalogModel.id && hasConfiguration($0) }
    }

    func installedModel(id: String) -> InstalledModel? {
        installed.first { $0.id == id }
    }

    /// Marks a freshly downloaded snapshot as installed and computes its real
    /// size. Idempotent: re-registering an existing model replaces it.
    func register(catalogModel: CatalogModel, sizeBytes: Int64) -> InstalledModel {
        let model = InstalledModel(
            id: catalogModel.id,
            repo: catalogModel.repo,
            addedAt: Date(),
            sizeBytes: sizeBytes)
        installed.removeAll { $0.id == model.id }
        installed.append(model)
        installed.sort { $0.addedAt > $1.addedAt }
        saveRegistry()
        return model
    }

    func uninstall(_ model: InstalledModel) {
        // Only delete from the managed Application Support folder. Models
        // living in an external base (legacy CLI folder, user import) get
        // de-registered but their files stay put — deleting repo-local or
        // user-owned directories would be surprising and destructive.
        if model.basePath == nil {
            try? fileManager.removeItem(at: directory(for: model))
        }
        installed.removeAll { $0.id == model.id }
        saveRegistry()
    }

    var totalDiskUsage: Int64 {
        installed.reduce(0) { $0 + $1.sizeBytes }
    }

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryURL),
              let models = try? JSONDecoder().decode([InstalledModel].self, from: data)
        else {
            return
        }
        installed = models
    }

    private func saveRegistry() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: registryURL, options: .atomic)
    }

    /// Pure directory scan, safe off the main actor. Only directories holding
    /// a complete snapshot (MLX or GGUF — the same check `hasConfiguration`
    /// uses) count as installed; half-downloaded models must surface as
    /// downloads, not as loadable models.
    nonisolated static func scanFromDisk(modelsDirectory baseURL: URL?) -> [InstalledModel] {
        guard let baseURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: baseURL.path)
        else { return [] }
        return names.compactMap { name -> InstalledModel? in
            guard let catalog = ModelCatalog.all.first(where: { $0.id == name }) else { return nil }
            let dir = baseURL.appendingPathComponent(name, isDirectory: true)
            guard let dirNames = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                  isCompleteSnapshot(dirNames: dirNames)
            else { return nil }
            let size = (try? sizeOfDirectory(dir)) ?? catalog.diskBytes
            return InstalledModel(
                id: name, repo: catalog.repo, addedAt: Date(), sizeBytes: size,
                basePath: baseURL.path)
        }
    }

    /// Re-syncs the registry with what's actually on disk: discovers models
    /// copied/imported outside the app (or registered by an interrupted
    /// import) and drops entries whose directories vanished. Existing entries
    /// keep their `addedAt`; discoveries in the managed folder get
    /// `basePath: nil` so uninstall deletes their files like any download.
    /// Called when the Model Manager appears — cheap (directory listings,
    /// sizing off-main), and it keeps the UI honest after external changes.
    func rescanFromDisk() {
        let base = modelsBaseURL
        let extras = Self.extraScanDirectories
        Task.detached(priority: .utility) {
            var scanned = Self.scanFromDisk(modelsDirectory: base)
            for extra in extras {
                scanned.append(contentsOf: Self.scanFromDisk(modelsDirectory: extra))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                var changed = false
                // Drop entries whose directories vanished or went incomplete.
                let before = self.installed.count
                self.installed.removeAll { model in
                    !self.fileManager.fileExists(atPath: self.directory(for: model).path)
                        || !self.hasConfiguration(model)
                }
                if self.installed.count != before { changed = true }
                // Discover new directories.
                for var found in scanned where !self.installed.contains(where: { $0.id == found.id }) {
                    if found.basePath == base.path { found.basePath = nil }
                    self.installed.append(found)
                    changed = true
                }
                if changed {
                    self.installed.sort { $0.addedAt > $1.addedAt }
                    self.saveRegistry()
                }
            }
        }
    }

    nonisolated static func sizeOfDirectory(_ url: URL) throws -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true, let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    nonisolated func directorySize(_ url: URL) throws -> Int64 {
        try Self.sizeOfDirectory(url)
    }
}