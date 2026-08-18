import Foundation

/// Parallel, resumable chunk fetching for large files (model weights).
///
/// A single-file download is split into fixed-size byte ranges; each range is
/// fetched with an HTTP `Range` request and written at its absolute offset in
/// a preallocated `.incomplete` file. Completed ranges are recorded in a
/// sidecar so pause/quit/relaunch resumes exactly where it left off — the
/// same durability contract as `SmartFileDownloader`, but per-CHUNK instead
/// of per-file-append.
///
/// All planning decisions are pure (`ChunkPlan` / `Logic`) and unit-tested
/// without a network.
final class ParallelChunkDownloader: @unchecked Sendable, FileDownloading {

    /// One byte range of the file.
    struct Chunk: Sendable, Equatable {
        var index: Int
        var offset: Int64
        var length: Int64

        var endOffset: Int64 { offset + length }
        /// HTTP Range header value (inclusive end).
        var rangeHeader: String { "bytes=\(offset)-\(endOffset - 1)" }
    }

    /// Persisted next to the partial file: which chunks are already on disk.
    struct SidecarState: Codable, Equatable {
        var etag: String
        var totalBytes: Int64
        var completedChunks: Set<Int>
    }

    enum ChunkError: Error, LocalizedError, Equatable {
        case serverChanged
        case unauthorized
        case notFound
        case rangeNotSupported
        case io(String)
        case paused

        var errorDescription: String? {
            switch self {
            case .serverChanged: return "The file changed on the server mid-download."
            case .unauthorized: return "Access denied — check the Hugging Face token in Settings."
            case .notFound: return "File not found on the Hugging Face Hub."
            case .rangeNotSupported: return "Server does not support ranged downloads."
            case .io(let detail): return "Could not write the download: \(detail)"
            case .paused: return "Download paused."
            }
        }
    }

    /// Pure planning logic — deterministic, unit-testable.
    enum Logic {

        /// Split a file into chunks of at most `chunkSize` bytes. The last
        /// chunk absorbs the remainder; a file smaller than one chunk is one
        /// chunk. Zero/negative sizes produce no chunks (caller falls back).
        static func plan(totalBytes: Int64, chunkSize: Int64) -> [Chunk] {
            guard totalBytes > 0, chunkSize > 0 else { return [] }
            let count = Int((totalBytes + chunkSize - 1) / chunkSize)
            return (0..<count).map { index in
                let offset = Int64(index) * chunkSize
                let length = min(chunkSize, totalBytes - offset)
                return Chunk(index: index, offset: offset, length: length)
            }
        }

        /// A persisted sidecar is reusable only when the server content is
        /// unchanged (same ETag) AND the recorded total matches.
        static func canReuseSidecar(_ sidecar: SidecarState?, etag: String, totalBytes: Int64) -> Bool {
            guard let sidecar else { return false }
            return sidecar.etag == etag && sidecar.totalBytes == totalBytes
        }

        /// How to proceed when the server answers a Range request.
        /// - 206: the server honored the range → keep writing at the offset.
        /// - 200: range ignored → the whole body must be re-fetched
        ///   sequentially (the caller aborts the parallel path).
        static func interpretRangeResponse(statusCode: Int) -> Int {
            statusCode
        }

        /// Chunk-concurrency target: enough to saturate a home connection
        /// without hammering the CDN or starving the UI.
        static func concurrency(totalBytes: Int64, chunkCount: Int, maxConcurrent: Int = 4) -> Int {
            guard totalBytes > 0 else { return 1 }
            return max(1, min(chunkCount, maxConcurrent))
        }

        /// Files below this size are not worth parallelizing (overhead > win).
        static func shouldParallelize(totalBytes: Int64, threshold: Int64 = 256 * 1024 * 1024) -> Bool {
            totalBytes >= threshold
        }
    }

    // MARK: State

    private let lock = NSLock()
    private let hub: any HubServing
    private let file: HubFile
    private let sourceURL: URL
    private let destination: URL
    private var incompleteURL: URL { destination.appendingPathExtension("incomplete") }
    private var sidecarURL: URL { destination.appendingPathExtension("incomplete.json") }
    private var state: SidecarState?
    private var cancelledFlag = false
    private var pausedFlag = false

    /// Total bytes across all completed chunks (for aggregate progress).
    var completedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let state, file.sizeBytes > 0 else { return 0 }
        let chunks = Logic.plan(totalBytes: file.sizeBytes, chunkSize: Self.chunkSize)
        return chunks
            .filter { state.completedChunks.contains($0.index) }
            .reduce(Int64(0)) { $0 + $1.length }
    }

    /// Fixed 128 MiB chunk size: large enough to amortize connection setup,
    /// small enough for fine-grained resume on multi-GB weights.
    static let chunkSize: Int64 = 128 * 1024 * 1024

    init(hub: any HubServing, file: HubFile, sourceURL: URL, destination: URL) {
        self.hub = hub
        self.file = file
        self.sourceURL = sourceURL
        self.destination = destination
        if let data = try? Data(contentsOf: sidecarURL),
           let decoded = try? JSONDecoder().decode(SidecarState.self, from: data) {
            self.state = decoded
        }
    }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    func pause() {
        lock.lock()
        pausedFlag = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag || pausedFlag
    }

    private var wasPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pausedFlag && !cancelledFlag
    }

    // MARK: Download

    /// Fetches all pending chunks with bounded concurrency, writing each at
    /// its absolute offset. Progress reports aggregate completed bytes.
    /// Returns `.paused` when paused mid-flight (sidecar persisted), throws
    /// on failure, completes when every chunk is on disk.
    func run(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let chunks = Logic.plan(totalBytes: file.sizeBytes, chunkSize: Self.chunkSize)
        guard !chunks.isEmpty else { throw ChunkError.io("empty file") }

        // Server content changed since the partial was written → restart.
        if let existing = state,
           !Logic.canReuseSidecar(existing, etag: file.etag, totalBytes: file.sizeBytes) {
            try? FileManager.default.removeItem(at: incompleteURL)
            state = nil
        }
        var sidecar = state ?? SidecarState(
            etag: file.etag, totalBytes: file.sizeBytes, completedChunks: [])

        try prepareFile(totalBytes: file.sizeBytes)

        let pending = chunks.filter { !sidecar.completedChunks.contains($0.index) }
        progress(completedBytesTotal(sidecar: sidecar, chunks: chunks), file.sizeBytes)

        // Bounded-concurrency pool; the sidecar is updated in completion
        // order inside runPool (single writer, no shared-mutable race).
        if !pending.isEmpty {
            try await runPool(pending: pending, sidecar: &sidecar, chunks: chunks, progress: progress)
        }

        // Final integrity + atomic rename.
        persist(sidecar)
        try verifySize()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: incompleteURL, to: destination)
        // Integrity parity with the sequential path: LFS files carry a
        // sha256; verify before the sidecar is removed.
        if let expected = file.sha256 {
            let actual = await HFHubClient.sha256Hex(ofFile: destination)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: destination)
                throw ChunkError.serverChanged
            }
        }
        try? FileManager.default.removeItem(at: sidecarURL)
        state = nil
    }

    /// Bounded-concurrency pool that reports each finished chunk back so the
    /// sidecar is updated in completion order (no shared-mutable race).
    private func runPool(
        pending: [Chunk],
        sidecar: inout SidecarState,
        chunks: [Chunk],
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let concurrency = Logic.concurrency(totalBytes: file.sizeBytes, chunkCount: pending.count)
        var iterator = pending.makeIterator()
        var inFlight = 0

        try await withThrowingTaskGroup(of: Chunk.self) { group in
            func submitNext() {
                while inFlight < concurrency, let chunk = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        try await self.fetch(chunk: chunk)
                        return chunk
                    }
                }
            }
            submitNext()
            while let finished = try await group.next() {
                inFlight -= 1
                if isStopped {
                    group.cancelAll()
                    persist(sidecar)
                    throw ChunkError.paused
                }
                sidecar.completedChunks.insert(finished.index)
                persist(sidecar)
                progress(completedBytesTotal(sidecar: sidecar, chunks: chunks), file.sizeBytes)
                submitNext()
            }
        }
    }

    /// Fetches one chunk with its Range request and writes it at the offset.
    private func fetch(chunk: Chunk) async throws {
        var request = hub.downloadRequest(url: sourceURL, offset: chunk.offset)
        request.setValue(chunk.rangeHeader, forHTTPHeaderField: "Range")
        let (bytes, response) = try await hub.response(for: request)

        switch response.statusCode {
        case 206:
            break
        case 200:
            throw ChunkError.rangeNotSupported
        case 401, 403:
            throw ChunkError.unauthorized
        case 404:
            throw ChunkError.notFound
        default:
            throw ChunkError.serverChanged
        }

        guard let handle = try? FileHandle(forWritingTo: incompleteURL) else {
            throw ChunkError.io("cannot open \(incompleteURL.path)")
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(chunk.offset))

        var received: Int64 = 0
        var buffer = [UInt8]()
        buffer.reserveCapacity(131_072)
        do {
            for try await byte in bytes {
                if Task.isCancelled || isStopped { throw ChunkError.paused }
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    try handle.write(contentsOf: Data(buffer))
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: Data(buffer))
                received += Int64(buffer.count)
            }
        } catch let error as ChunkError {
            throw error
        } catch is CancellationError {
            throw ChunkError.paused
        } catch {
            throw ChunkError.serverChanged
        }

        guard received == chunk.length else {
            throw ChunkError.serverChanged
        }
    }

    // MARK: Helpers

    private func prepareFile(totalBytes: Int64) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            throw ChunkError.io("cannot create \(destination.deletingLastPathComponent().path)")
        }
        if !fm.fileExists(atPath: incompleteURL.path) {
            guard fm.createFile(atPath: incompleteURL.path, contents: nil) else {
                throw ChunkError.io("cannot create \(incompleteURL.path)")
            }
        }
        // Preallocate to full size so chunks can write at absolute offsets.
        guard let handle = try? FileHandle(forWritingTo: incompleteURL) else {
            throw ChunkError.io("cannot open \(incompleteURL.path)")
        }
        defer { try? handle.close() }
        let attributes = (try? fm.attributesOfItem(atPath: incompleteURL.path)) ?? [:]
        let currentSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if currentSize < totalBytes {
            try handle.truncate(atOffset: UInt64(totalBytes))
        }
    }

    private func verifySize() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: incompleteURL.path)
        let finalSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if file.sizeBytes > 0, finalSize != file.sizeBytes {
            throw ChunkError.serverChanged
        }
    }

    private func completedBytesTotal(sidecar: SidecarState, chunks: [Chunk]) -> Int64 {
        chunks
            .filter { sidecar.completedChunks.contains($0.index) }
            .reduce(Int64(0)) { $0 + $1.length }
    }

    private func persist(_ sidecar: SidecarState) {
        lock.lock()
        state = sidecar
        lock.unlock()
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: sidecarURL, options: .atomic)
    }
}
