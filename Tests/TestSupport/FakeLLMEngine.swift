import Foundation
@testable import BeetCode

/// A fully scripted, deterministic LLMEngine for agent-loop tests. No model
/// weights, no Metal, no network — every generation returns the next scripted
/// response, and every stream(adding:) call records the exact turns it was
/// given so tests can assert history sequencing.
final class FakeLLMEngine: LLMEngine, @unchecked Sendable {

    /// A scripted generation outcome, consumed FIFO by stream(adding:).
    enum Scripted: Sendable {
        /// Yield `text` in small chunks, then finish.
        case text(String)
        /// Finish without yielding anything.
        case empty
        /// Throw the error (used to simulate engine failures).
        case failure(any Error & Sendable)
    }

    private let lock = NSLock()

    // Script state.
    private var script: [Scripted] = []
    private var holdsNextStream = false

    // Recorded behavior (asserted by tests).
    private var recordedTurns: [[ChatTurn]] = []
    private var resetCount = 0
    private var cancelCount = 0
    private var streamCount = 0

    // Runtime state.
    private var cancelRequested = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var loadedID: String?
    private var statsState = EngineStats()

    // MARK: Scripting (test side) — all sync, safe from any context

    func enqueue(_ responses: Scripted...) {
        withLock {
            script.append(contentsOf: responses)
        }
    }

    func enqueue(texts: [String]) {
        withLock {
            script.append(contentsOf: texts.map(Scripted.text))
        }
    }

    /// When true, the next stream(adding:) call blocks until release() is
    /// called — giving tests a deterministic point at which to cancel.
    func holdNextStream() {
        withLock { holdsNextStream = true }
    }

    func release() {
        let continuation = withLock { () -> CheckedContinuation<Void, Never>? in
            let held = holdContinuation
            holdContinuation = nil
            return held
        }
        continuation?.resume()
    }

    var streamCallCount: Int {
        withLock { streamCount }
    }

    var resetCallCount: Int {
        withLock { resetCount }
    }

    var cancelCallCount: Int {
        withLock { cancelCount }
    }

    /// All stream(adding:) turn-arguments, in call order.
    var turnHistory: [[ChatTurn]] {
        withLock { recordedTurns }
    }

    var isCancelRequested: Bool {
        withLock { cancelRequested }
    }

    // MARK: LLMEngine

    var loadedModelID: String? {
        get async { withLock { loadedID } }
    }

    var stats: EngineStats {
        get async { withLock { statsState } }
    }

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        withLock { loadedID = modelID }
    }

    func unload() async {
        withLock {
            loadedID = nil
            statsState = EngineStats()
        }
    }

    func reset() async {
        withLock {
            resetCount += 1
            cancelRequested = false
        }
    }

    func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        let (response, shouldHold) = withLock { () -> (Scripted, Bool) in
            recordedTurns.append(turns)
            streamCount += 1
            let response: Scripted = script.isEmpty ? .empty : script.removeFirst()
            let shouldHold = holdsNextStream
            holdsNextStream = false
            return (response, shouldHold)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                // Deterministic cancellation point: block until released.
                if shouldHold {
                    _ = await withCheckedContinuation { inner in
                        let resumeNow = withLock { () -> Bool in
                            if cancelRequested {
                                return true
                            }
                            holdContinuation = inner
                            return false
                        }
                        if resumeNow { inner.resume() }
                    }
                }

                if self.isCancelRequested {
                    continuation.finish(throwing: CancellationError())
                    return
                }

                switch response {
                case .text(let text):
                    // Yield in character chunks so tokenDelta events flow.
                    var index = text.startIndex
                    while index < text.endIndex {
                        if self.isCancelRequested {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex) ?? text.endIndex
                        continuation.yield(String(text[index..<next]))
                        index = next
                    }
                    continuation.finish()
                case .empty:
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func cancelGeneration() async {
        let held = withLock { () -> CheckedContinuation<Void, Never>? in
            cancelCount += 1
            cancelRequested = true
            let held = holdContinuation
            holdContinuation = nil
            return held
        }
        held?.resume()
    }

    // MARK: Locking

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Convenience for tests that need the failure case without carrying an
/// arbitrary error type.
enum FakeEngineTestError: Error, LocalizedError, Sendable {
    case simulated

    var errorDescription: String? { "simulated engine failure" }
}