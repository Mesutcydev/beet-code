import Foundation

/// Persisted description of an in-flight model download so pause → quit →
/// relaunch → resume works without the UI being open.
struct DownloadManifest: Codable, Sendable, Equatable {
    var modelID: String
    var repo: String
    var directoryPath: String
    var totalBytes: Int64
    var updatedAt: Date
    /// True when the orchestrator was mid-file (not merely paused by user).
    var wasInterrupted: Bool = false
    var schemaVersion: Int = 1
}

/// Common control surface for both download paths (sequential single-stream
/// and parallel chunked), so the orchestrator can pause/cancel either.
protocol FileDownloading: AnyObject, Sendable {
    func pause()
    func cancel()
}

extension SmartFileDownloader: FileDownloading {}

/// Orchestrates a whole-model snapshot download (many files; large weight
/// files fetch their byte ranges in parallel, everything else streams
/// sequentially) and publishes UI-ready progress. Owned by AppState; the UI
/// drives it via `start/pause/cancel` only — start doubles as resume
/// (completed files are skipped, partial files resume from their sidecar
/// byte offset or chunk set). Finalization (registration into ModelStore)
/// happens through `onCompletion`, never through UI row callbacks, so it is
/// idempotent even when the Model Manager sheet is closed.
@MainActor
final class ModelDownloadManager: ObservableObject {

    struct Progress: Sendable, Equatable {
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var currentFile: String = ""

        var fraction: Double {
            totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
        }
    }

    enum State: Sendable, Equatable {
        case idle
        case preparing
        case downloading(Progress)
        case paused(Progress)
        case completed
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .downloading: true
            default: false
            }
        }

        var progress: Progress? {
            switch self {
            case .downloading(let p), .paused(let p): p
            default: nil
            }
        }
    }

    @Published private(set) var states: [String: State] = [:]

    /// Invoked when a whole-model download completes (registration and model
    /// activation live in AppState).
    var onCompletion: (@MainActor (String) -> Void)?

    private let tokenProvider: @Sendable () -> String?
    private let hubOverride: (any HubServing)?
    private var orchestrationTasks: [String: Task<Void, Never>] = [:]
    private var activeDownloaders: [String: any FileDownloading] = [:]
    private var cancelledModelIDs: Set<String> = []

    init(
        tokenProvider: @escaping @Sendable () -> String?,
        hub: (any HubServing)? = nil
    ) {
        self.tokenProvider = tokenProvider
        self.hubOverride = hub
        restorePausedDownloads()
    }

    func state(for modelID: String) -> State {
        states[modelID] ?? .idle
    }

    // MARK: Manifest persistence

    private var manifestsDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeetCode/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manifestURL(for modelID: String) -> URL {
        manifestsDirectory.appendingPathComponent("\(modelID).json")
    }

    private func saveManifest(_ manifest: DownloadManifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL(for: manifest.modelID), options: .atomic)
    }

    private func removeManifest(modelID: String) {
        try? FileManager.default.removeItem(at: manifestURL(for: modelID))
    }

    /// Called at startup: every persisted manifest becomes a paused state,
    /// ready for explicit resume (or opt-in auto-resume by AppState).
    func restorePausedDownloads() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: manifestsDirectory.path) else {
            return
        }
        for name in names where name.hasSuffix(".json") {
            let url = manifestsDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data)
            else { continue }
            states[manifest.modelID] = .paused(
                Progress(
                    completedBytes: 0,
                    totalBytes: manifest.totalBytes,
                    currentFile: "resumable"))
        }
    }

    /// Model IDs with persisted manifests (for auto-resume).
    var resumableModelIDs: [String] {
        states.compactMap { modelID, state in
            if case .paused = state { return modelID }
            return nil
        }.sorted()
    }

    /// Whether a model has a persisted interrupted download.
    func hasInterruptedDownload(modelID: String) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(for: modelID).path)
    }

    // MARK: Control

    func start(model: CatalogModel, into directory: URL) {
        guard state(for: model.id).isActive == false else { return }
        cancelledModelIDs.remove(model.id)
        let modelID = model.id
        states[modelID] = .preparing
        saveManifest(
            DownloadManifest(
                modelID: modelID,
                repo: model.repo,
                directoryPath: directory.path,
                totalBytes: model.diskBytes,
                updatedAt: Date()))

        let provider = tokenProvider
        let hub = hubOverride ?? HFHubClient(tokenProvider: provider)
        orchestrationTasks[modelID] = Task.detached(priority: .utility) { [weak self] in
            await self?.run(model: model, into: directory, hub: hub)
        }
    }

    /// Pauses the in-flight file transfer; the orchestrator observes the
    /// pause and settles into `.paused` with the exact byte count.
    func pause(modelID: String) {
        activeDownloaders[modelID]?.pause()
    }

    /// Hard cancel: stops everything and deletes partial state. A cancelled
    /// model can never be overwritten as `.paused` by the finishing task.
    func cancel(modelID: String, directory: URL) {
        cancelledModelIDs.insert(modelID)
        activeDownloaders[modelID]?.cancel()
        orchestrationTasks[modelID]?.cancel()
        orchestrationTasks[modelID] = nil
        activeDownloaders[modelID] = nil
        states[modelID] = .idle
        removeManifest(modelID: modelID)
        Task.detached(priority: .utility) {
            Self.removePartials(in: directory)
        }
    }

    // MARK: Orchestration

    /// Terminal outcome of one file transfer, abstracted over the two
    /// downloader implementations.
    private enum FileOutcome {
        case success
        case paused
        case failed(String)
    }

    /// Downloads one file, choosing the transport by size: large files fetch
    /// fixed byte ranges in parallel (faster on the weight files that
    /// dominate download time); small files stream sequentially. Both paths
    /// are resumable and report aggregate progress.
    private func downloadFile(
        file: HubFile,
        partialBytes: Int64,
        fileBase: Int64,
        total: Int64,
        modelID: String,
        repo: String,
        directory: URL,
        hub: any HubServing
    ) async -> FileOutcome {
        let destination = directory.appendingPathComponent(file.path)
        let source = hub.resolveURL(repo: repo, path: file.path)
        let fileName = (file.path as NSString).lastPathComponent

        // Large files → parallel ranged chunks; everything else → sequential.
        if ParallelChunkDownloader.Logic.shouldParallelize(totalBytes: file.sizeBytes) {
            return await downloadFileParallel(
                file: file, source: source, destination: destination,
                fileBase: fileBase, total: total, modelID: modelID,
                fileName: fileName, hub: hub)
        }
        return await downloadFileSequential(
            file: file, partialBytes: partialBytes, source: source,
            destination: destination, fileBase: fileBase, total: total,
            modelID: modelID, fileName: fileName, hub: hub)
    }

    private func downloadFileSequential(
        file: HubFile,
        partialBytes: Int64,
        source: URL,
        destination: URL,
        fileBase: Int64,
        total: Int64,
        modelID: String,
        fileName: String,
        hub: any HubServing
    ) async -> FileOutcome {
        let downloader = SmartFileDownloader(
            hub: hub, file: file, sourceURL: source, destination: destination)
        activeDownloaders[modelID] = downloader

        let result: Result<URL, SmartFileDownloader.DownloadError> =
            await withCheckedContinuation { continuation in
                downloader.start(
                    progress: { [weak self] done, _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            // The downloader's `done` is relative to the
                            // ACTUAL resumed offset (0 after an ETag
                            // restart), so progress never over-reports stale
                            // partial bytes.
                            let resumed = downloader.resumedOffset
                            self.states[modelID] = .downloading(
                                Progress(
                                    completedBytes: fileBase + resumed + done,
                                    totalBytes: total,
                                    currentFile: fileName))
                        }
                    },
                    completion: { continuation.resume(returning: $0) })
            }
        activeDownloaders[modelID] = nil

        switch result {
        case .success: return .success
        case .failure(let error) where error == .paused: return .paused
        case .failure(let error): return .failed(error.localizedDescription)
        }
    }

    private func downloadFileParallel(
        file: HubFile,
        source: URL,
        destination: URL,
        fileBase: Int64,
        total: Int64,
        modelID: String,
        fileName: String,
        hub: any HubServing
    ) async -> FileOutcome {
        let downloader = ParallelChunkDownloader(
            hub: hub, file: file, sourceURL: source, destination: destination)
        activeDownloaders[modelID] = downloader

        do {
            try await downloader.run { [weak self] done, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.states[modelID] = .downloading(
                        Progress(
                            completedBytes: fileBase + done,
                            totalBytes: total,
                            currentFile: fileName))
                }
            }
            activeDownloaders[modelID] = nil
            return .success
        } catch ParallelChunkDownloader.ChunkError.paused {
            activeDownloaders[modelID] = nil
            return .paused
        } catch ParallelChunkDownloader.ChunkError.rangeNotSupported {
            activeDownloaders[modelID] = nil
            // The server ignored the Range request (200 instead of 206), so
            // the parallel path cannot make progress. Drop the chunk
            // artifacts (preallocated .incomplete + chunk sidecar would be
            // misread as a resumable sequential partial) and re-download
            // sequentially — SmartFileDownloader's 200-handling truncates
            // stale partials, so the restart is clean.
            let fm = FileManager.default
            try? fm.removeItem(at: destination.appendingPathExtension("incomplete"))
            try? fm.removeItem(at: destination.appendingPathExtension("incomplete.json"))
            return await downloadFileSequential(
                file: file, partialBytes: 0, source: source, destination: destination,
                fileBase: fileBase, total: total, modelID: modelID,
                fileName: fileName, hub: hub)
        } catch let error as ParallelChunkDownloader.ChunkError {
            activeDownloaders[modelID] = nil
            return .failed(error.localizedDescription)
        } catch {
            activeDownloaders[modelID] = nil
            return .failed(error.localizedDescription)
        }
    }

    private func run(model: CatalogModel, into directory: URL, hub: any HubServing) async {
        let modelID = model.id
        do {
            // Fresh metadata doubles as etag-change detection for partials.
            let files = try await hub.listModelFiles(repo: model.repo)
            guard !files.isEmpty else {
                throw HFHubClient.HubError.repoNotFound(model.repo)
            }
            let total = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
            guard total > 0 else {
                throw HFHubClient.HubError.badResponse("repo reports zero bytes")
            }

            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // Split into already-complete files (skip) and pending files.
            var pending: [(file: HubFile, partialBytes: Int64)] = []
            var completed: Int64 = 0
            for file in files {
                let destination = directory.appendingPathComponent(file.path)
                if Self.isComplete(file: file, at: destination) {
                    completed += file.sizeBytes
                } else {
                    pending.append((file, Self.partialSize(near: destination)))
                }
            }

            for (file, partialBytes) in pending {
                if Task.isCancelled || cancelledModelIDs.contains(modelID) { break }

                let outcome = await downloadFile(
                    file: file,
                    partialBytes: partialBytes,
                    fileBase: completed,
                    total: total,
                    modelID: modelID,
                    repo: model.repo,
                    directory: directory,
                    hub: hub)

                switch outcome {
                case .success:
                    completed += file.sizeBytes
                case .paused:
                    guard !cancelledModelIDs.contains(modelID) else {
                        states[modelID] = .idle
                        orchestrationTasks[modelID] = nil
                        return
                    }
                    states[modelID] = .paused(
                        Progress(completedBytes: completed, totalBytes: total))
                    saveManifest(
                        DownloadManifest(
                            modelID: modelID,
                            repo: model.repo,
                            directoryPath: directory.path,
                            totalBytes: total,
                            updatedAt: Date(),
                            wasInterrupted: false))
                    orchestrationTasks[modelID] = nil
                    return
                case .failed(let message):
                    states[modelID] = .failed(message)
                    orchestrationTasks[modelID] = nil
                    return
                }
            }

            if Task.isCancelled || cancelledModelIDs.contains(modelID) {
                states[modelID] = .idle
                removeManifest(modelID: modelID)
            } else {
                states[modelID] = .completed
                removeManifest(modelID: modelID)
                // The completion handler is MainActor-isolated; hop
                // explicitly from this detached task.
                let completion = onCompletion
                if let completion {
                    Task { @MainActor in completion(modelID) }
                }
            }
            orchestrationTasks[modelID] = nil
        } catch {
            if cancelledModelIDs.contains(modelID) {
                states[modelID] = .idle
            } else {
                states[modelID] = .failed(error.localizedDescription)
            }
            orchestrationTasks[modelID] = nil
        }
    }

    // MARK: Disk helpers

    nonisolated private static func isComplete(file: HubFile, at destination: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value
        return size == file.sizeBytes && file.sizeBytes > 0
    }

    nonisolated private static func partialSize(near destination: URL) -> Int64 {
        let incomplete = URL(fileURLWithPath: destination.path + ".incomplete")
        let attributes = try? FileManager.default.attributesOfItem(atPath: incomplete.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated private static func removePartials(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for case let url as URL in enumerator where url.lastPathComponent.contains(".incomplete") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}