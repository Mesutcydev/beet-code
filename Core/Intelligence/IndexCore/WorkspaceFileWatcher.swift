import CoreServices
import Foundation

/// Filesystem watcher over FSEvents (spec §27). Streams events for the
/// workspace root, debounces bursts (editors write in flurries), and reports
/// coalesced change notifications. The watcher reports PATHS; re-hashing and
/// delta computation happen in IndexEngine — the watcher itself decides
/// nothing about content.
final class WorkspaceFileWatcher: @unchecked Sendable {

    /// One debounced batch of filesystem changes.
    struct ChangeBatch: Sendable {
        /// Workspace-relative paths FSEvents flagged. FSEvents is
        /// directory-granular on some paths; consumers must re-hash rather
        /// than trust the event kind.
        let paths: [String]
    }

    private let root: URL
    private let debounceInterval: TimeInterval
    private let handler: (ChangeBatch) -> Void

    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pendingPaths: Set<String> = []
    private var flushTask: Task<Void, Never>?

    /// - Parameters:
    ///   - root: workspace root (canonical path).
    ///   - debounceInterval: quiet period before a batch fires (default 0.4s).
    ///   - handler: called on a background queue with each debounced batch.
    init(root: URL, debounceInterval: TimeInterval = 0.4,
         handler: @escaping (ChangeBatch) -> Void) {
        self.root = root
        self.debounceInterval = debounceInterval
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let paths = [root.path] as CFArray
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
            // UseCFTypes is set below: eventPaths is a CFArray of CFString.
            let pathsArray = unsafeBitCast(eventPaths, to: CFArray.self)
            var collected: [String] = []
            for i in 0..<count {
                let value = unsafeBitCast(CFArrayGetValueAtIndex(pathsArray, i), to: CFString.self)
                collected.append(value as String)
            }
            watcher.note(paths: collected)
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Log.intelligence.error("FSEventStreamCreate failed for \(self.root.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.beetcode.fswatcher"))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        flushTask?.cancel()
        flushTask = nil
        pendingPaths.removeAll()
        lock.unlock()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func note(paths: [String]) {
        lock.lock()
        for path in paths {
            pendingPaths.insert(Self.relative(path, root: root.path))
        }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(Int(self.debounceInterval * 1000)))
            guard !Task.isCancelled else { return }
            self.flush()
        }
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let batch = ChangeBatch(paths: pendingPaths.sorted())
        pendingPaths.removeAll()
        lock.unlock()
        if !batch.paths.isEmpty { handler(batch) }
    }

    private static func relative(_ path: String, root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
