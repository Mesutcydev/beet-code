import Foundation

/// Synchronous process-level wrapper around IntelligenceCLI (which is async
/// for indexing). Used only by the app binary's `intel` early-exit path —
/// never from UI code.
enum IntelligenceCLIRunner {
    static func run(_ arguments: [String]) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedCode()
        Task {
            let code = await IntelligenceCLI.run(arguments: arguments)
            result.set(code)
            semaphore.signal()
        }
        semaphore.wait()
        return result.value
    }

    /// Lock-boxed exit code so the semaphore handoff stays Sendable-clean.
    private final class LockedCode: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32 = 0
        func set(_ code: Int32) { lock.lock(); stored = code; lock.unlock() }
        var value: Int32 { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
