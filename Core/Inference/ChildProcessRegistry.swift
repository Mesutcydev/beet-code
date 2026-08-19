import Foundation

/// Process-wide registry of child processes the app spawns (today:
/// llama-server instances backing GGUF models).
///
/// Why: quitting the app while a GGUF model is loaded used to orphan
/// llama-server — a multi-GB process serving weights nobody can reach.
/// `applicationWillTerminate` can't await the engines' async unload path,
/// so every spawn registers here and the app delegate SIGTERMs whatever is
/// still alive, synchronously, on the way out.
///
/// (A hard crash still leaks the child — willTerminate doesn't fire on
/// SIGABRT. The next launch is unaffected: each server gets a fresh port.)
enum ChildProcessRegistry {

    private static let lock = NSLock()
    // All access under `lock` — `nonisolated(unsafe)` is how this codebase
    // marks lock-guarded statics (same pattern as VisionProvider's seams).
    nonisolated(unsafe) private static var processes: [pid_t: Process] = [:]

    static func register(_ process: Process) {
        lock.withLock { processes[process.processIdentifier] = process }
    }

    static func unregister(_ process: Process) {
        lock.withLock { processes[process.processIdentifier] = nil }
    }

    /// Best-effort SIGTERM to every registered child still running.
    /// Synchronous and signal-safe enough for applicationWillTerminate.
    static func terminateAll() {
        let running = lock.withLock { Array(processes.values) }
        for process in running where process.isRunning {
            process.terminate()
        }
    }

    /// Test hook: how many children are currently tracked.
    static var trackedCount: Int {
        lock.withLock { processes.count }
    }
}
