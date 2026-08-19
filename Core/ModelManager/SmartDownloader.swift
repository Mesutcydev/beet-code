import Foundation

/// Resumable, integrity-checked file download using explicit HTTP Range
/// requests. State survives app termination via a sidecar JSON file next to
/// the `.incomplete` partial file, so pause → quit → relaunch → resume works
/// without URLSession resume data.
///
/// Pure decision logic lives in `SmartFileDownloader.Logic` so it is unit
/// testable without a network.
final class SmartFileDownloader: @unchecked Sendable {

    enum Phase: Sendable, Equatable {
        case idle
        case downloading
        case paused
        case verifying
        case completed
        case failed(String)
    }

    enum DownloadError: Error, LocalizedError, Equatable {
        case checksumMismatch
        case serverChanged
        case notFound
        case unauthorized
        case diskFull(needed: Int64, free: Int64)
        case io(String)
        case cancelled
        case paused

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                return "Downloaded file failed its SHA-256 integrity check and was deleted."
            case .serverChanged:
                return "The file changed on the server mid-download."
            case .notFound: return "File not found on the Hugging Face Hub."
            case .unauthorized: return "Access denied — add a valid Hugging Face token in Settings."
            case .diskFull(let needed, let free):
                return "Not enough disk space: need \(ByteFormatter.bytes(needed)), \(ByteFormatter.bytes(free)) free."
            case .io(let detail): return "Could not write the download: \(detail)"
            case .cancelled: return "Download cancelled."
            case .paused: return "Download paused."
            }
        }

        /// Failures worth retrying with backoff.
        var isRetryable: Bool {
            switch self {
            case .checksumMismatch, .serverChanged: true
            case .notFound, .unauthorized, .diskFull, .io, .cancelled, .paused: false
            }
        }
    }

    /// Persisted beside the partial file so resume works across launches.
    struct SidecarState: Codable, Equatable {
        var etag: String
        var totalBytes: Int64
        var completedBytes: Int64
        var sha256: String?
    }

    /// All pure decisions, testable without network.
    enum Logic {

        /// A partial download is usable only when the server content is
        /// unchanged; otherwise restart from zero.
        static func shouldRestartPartial(sidecar: SidecarState?, currentETag: String) -> Bool {
            guard let sidecar else { return false }
            return sidecar.etag != currentETag
        }

        /// Response to a Range request: 206 continues; 200 means the server
        /// ignored the range — the partial must be truncated.
        static func mustTruncatePartial(statusCode: Int, resumedFromOffset: Int64) -> Bool {
            statusCode == 200 && resumedFromOffset > 0
        }

        /// Exponential backoff with ±25% jitter, honoring Retry-After when present.
        static func retryDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
            if let retryAfter, retryAfter > 0, retryAfter <= 300 { return retryAfter }
            let base = 1.5 * pow(2.0, Double(attempt - 1))
            let jitter = Double.random(in: -0.25...0.25) * base
            return min(60, max(0.5, base + jitter))
        }

        /// Hard-fail when free disk cannot hold the remaining bytes plus a
        /// safety margin.
        static func diskPreflight(pendingBytes: Int64, freeBytes: Int64) -> DownloadError? {
            let margin = max(200_000_000, pendingBytes / 20)
            if freeBytes < pendingBytes + margin {
                return .diskFull(needed: pendingBytes + margin, free: freeBytes)
            }
            return nil
        }
    }

    // MARK: State

    private let lock = NSLock()
    private var _phase: Phase = .idle
    private var currentTask: Task<Void, Never>?
    private(set) var sidecar: SidecarState?
    private var _resumedOffset: Int64 = 0

    /// The byte offset the transfer actually resumed from. Re-read after the
    /// first progress tick: an ETag change restarts at 0, and the sidecar's
    /// recorded count is reconciled against the real partial file size.
    var resumedOffset: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _resumedOffset
    }

    private func setResumedOffset(_ offset: Int64) {
        lock.lock()
        _resumedOffset = offset
        lock.unlock()
    }

    var phase: Phase {
        lock.lock()
        defer { lock.unlock() }
        return _phase
    }

    let destination: URL
    private var incompleteURL: URL { destination.appendingPathExtension("incomplete") }
    private var sidecarURL: URL { destination.appendingPathExtension("incomplete.json") }
    private let hub: any HubServing
    private let file: HubFile
    private let sourceURL: URL
    private let maxAttempts = 3

    init(hub: any HubServing, file: HubFile, sourceURL: URL, destination: URL) {
        self.hub = hub
        self.file = file
        self.sourceURL = sourceURL
        self.destination = destination
        self.sidecar = Self.loadSidecar(at: sidecarURL)
    }

    // MARK: Control

    /// Starts (or resumes) the download. Progress callback fires on a
    /// background thread; `completed`/`failed` fire exactly once.
    func start(
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        completion: @escaping @Sendable (Result<URL, DownloadError>) -> Void
    ) {
        lock.lock()
        guard currentTask == nil else {
            lock.unlock()
            return
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let result = await self.runWithRetries(progress: progress)
            // Completion must fire for every terminal outcome — including
            // pause — so the orchestrator's continuation never dangles.
            completion(result)
        }
        currentTask = task
        lock.unlock()
    }

    /// Pauses: cancels the running transfer; sidecar already reflects progress.
    func pause() {
        lock.lock()
        defer { lock.unlock() }
        guard case .downloading = _phase else { return }
        currentTask?.cancel()
        _phase = .paused
        persistSidecar()
    }

    /// Hard cancel: stops and deletes partial state.
    func cancel() {
        lock.lock()
        currentTask?.cancel()
        _phase = .idle
        lock.unlock()
        try? FileManager.default.removeItem(at: incompleteURL)
        try? FileManager.default.removeItem(at: sidecarURL)
        sidecar = nil
    }

    // MARK: Transfer

    private func runWithRetries(
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Result<URL, DownloadError> {
        var attempt = 0
        var lastError: DownloadError = .cancelled

        while attempt < maxAttempts {
            attempt += 1
            setPhase(.downloading)
            do {
                try await transferOnce(progress: progress)
                setPhase(.verifying)
                if let expected = file.sha256 {
                    let actual = await HFHubClient.sha256Hex(ofFile: destination)
                    guard actual == expected else {
                        try? FileManager.default.removeItem(at: destination)
                        throw DownloadError.checksumMismatch
                    }
                }
                cleanupPartial()
                setPhase(.completed)
                return .success(destination)
            } catch let error as DownloadError {
                lastError = error
                if error == .paused {
                    setPhase(.paused)
                    return .failure(.paused)
                }
                if !error.isRetryable || attempt >= maxAttempts {
                    break
                }
                Log.downloads.warning("File \(self.file.path) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(Logic.retryDelay(attempt: attempt, retryAfter: nil)))
            } catch {
                // Transport errors (timeouts, resets, DNS) — retryable.
                lastError = .serverChanged
                if attempt >= maxAttempts { break }
                try? await Task.sleep(for: .seconds(Logic.retryDelay(attempt: attempt, retryAfter: nil)))
            }
            if Task.isCancelled {
                setPhase(.paused)
                return .failure(.paused)
            }
        }

        // Surface a clean message for common transport failures.
        if lastError == .serverChanged {
            lastError = .serverChanged
        }
        setPhase(.failed(lastError.localizedDescription))
        return .failure(lastError)
    }

    private func transferOnce(
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let fm = FileManager.default

        // Server moved on? Discard the partial.
        if Logic.shouldRestartPartial(sidecar: sidecar, currentETag: file.etag) {
            try? fm.removeItem(at: incompleteURL)
            sidecar = nil
        }

        var state = sidecar ?? SidecarState(
            etag: file.etag, totalBytes: file.sizeBytes, completedBytes: 0, sha256: file.sha256)

        // Reconcile the sidecar's recorded count with the actual partial file:
        // a crash mid-append leaves the file smaller than the sidecar claims.
        if let partialSize = try? FileManager.default.attributesOfItem(atPath: incompleteURL.path)[.size] as? NSNumber,
           let recorded = partialSize.int64Value as Int64?, state.completedBytes > recorded {
            state.completedBytes = recorded
            persistSidecar()
        }

        // Disk preflight on the remaining bytes.
        let free = try freeDiskBytes(at: destination.deletingLastPathComponent())
        if let error = Logic.diskPreflight(pendingBytes: file.sizeBytes - state.completedBytes, freeBytes: free) {
            throw error
        }

        let resumeOffset = state.completedBytes
        setResumedOffset(resumeOffset)
        let request = hub.downloadRequest(url: sourceURL, offset: resumeOffset)
        let (bytes, response) = try await hub.response(for: request)

        switch response.statusCode {
        case 206:
            break
        case 200:
            if Logic.mustTruncatePartial(statusCode: 200, resumedFromOffset: resumeOffset) {
                try? fm.removeItem(at: incompleteURL)
                state.completedBytes = 0
            }
        case 401, 403:
            throw DownloadError.unauthorized
        case 404:
            throw DownloadError.notFound
        default:
            throw DownloadError.serverChanged
        }

        // Open partial for append (create if fresh). The downloader owns its
        // destination path, parents included.
        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            throw DownloadError.io("cannot create \(destination.deletingLastPathComponent().path)")
        }
        if !fm.fileExists(atPath: incompleteURL.path) {
            guard fm.createFile(atPath: incompleteURL.path, contents: nil) else {
                throw DownloadError.io("cannot create \(incompleteURL.path)")
            }
        }
        guard let handle = try? FileHandle(forWritingTo: incompleteURL) else {
            throw DownloadError.io("cannot open \(incompleteURL.path)")
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()

        var lastPersist = Date()
        var lastProgress = Date()

        do {
            // Buffer per-byte iteration into 64 KiB writes; the network is
            // the bottleneck, not this loop.
            var buffer = [UInt8]()
            buffer.reserveCapacity(131_072)
            for try await byte in bytes {
                if Task.isCancelled { throw DownloadError.paused }
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    try handle.write(contentsOf: Data(buffer))
                    state.completedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)

                    let now = Date()
                    if now.timeIntervalSince(lastProgress) > 0.1 {
                        lastProgress = now
                        progress(state.completedBytes, file.sizeBytes)
                    }
                    if now.timeIntervalSince(lastPersist) > 2 {
                        lastPersist = now
                        persistSidecar(state)
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: Data(buffer))
                state.completedBytes += Int64(buffer.count)
            }
        } catch let error as DownloadError {
            persistSidecar(state)
            throw error
        } catch is CancellationError {
            persistSidecar(state)
            throw DownloadError.paused
        } catch {
            // Transport failure (reset, timeout, DNS): retryable.
            persistSidecar(state)
            throw DownloadError.serverChanged
        }

        // Final size sanity check + atomic rename.
        let attributes = try fm.attributesOfItem(atPath: incompleteURL.path)
        let finalSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if file.sizeBytes > 0, finalSize != file.sizeBytes {
            persistSidecar(state)
            throw DownloadError.serverChanged
        }
        sidecar = state
        persistSidecar(state)
        progress(state.completedBytes, file.sizeBytes)

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: incompleteURL, to: destination)
    }

    // MARK: Sidecar + helpers

    private func setPhase(_ newPhase: Phase) {
        lock.lock()
        _phase = newPhase
        lock.unlock()
    }

    private func persistSidecar(_ state: SidecarState? = nil) {
        let value = state ?? sidecar
        guard let value,
              let data = try? JSONEncoder().encode(value)
        else { return }
        sidecar = value
        try? data.write(to: sidecarURL, options: .atomic)
    }

    private func cleanupPartial() {
        try? FileManager.default.removeItem(at: sidecarURL)
        sidecar = nil
    }

    private static func loadSidecar(at url: URL) -> SidecarState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SidecarState.self, from: data)
    }

    private func freeDiskBytes(at url: URL) throws -> Int64 {
        var value = statfs()
        let result = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return statfs(pointer, &value)
        }
        guard result == 0 else { return .max }
        let free = UInt64(value.f_bavail) * UInt64(value.f_bsize)
        return Int64(min(free, UInt64(Int64.max)))
    }
}