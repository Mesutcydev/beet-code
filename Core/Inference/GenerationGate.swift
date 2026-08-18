import Foundation
import os

/// Serializes all Metal-touching work onto a single task chain.
///
/// MLX crashes the process (uncatchable C++ exception → SIGABRT) when two
/// command buffers are in flight concurrently, and `Memory.clearCache()` is
/// unsafe while a buffer executes. Every MLX operation therefore funnels
/// through this gate:
/// - work runs on a tail-chained task, one at a time;
/// - `cancelAll()` bumps a generation counter so queued-but-not-started work
///   self-skips (in-flight Metal work is left alone — it cannot be safely
///   interrupted mid-command-buffer);
/// - cache clears are enqueued as the new tail so they run only once the
///   current generation finishes.
///
/// Pattern adapted from the ios-local-llm project's `MLXGenerationGate` (MIT).
public actor GenerationGate {

    public struct Superseded: Error, CustomStringConvertible {
        public let description = "Generation was superseded by a newer request or cancelled."
    }

    private final class Counter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var value: UInt64 = 0

        func bump() -> UInt64 {
            lock.withLock {
                value &+= 1
                return value
            }
        }

        var current: UInt64 {
            lock.withLock { value }
        }
    }

    private let counter = Counter()
    private var tail: Task<Void, Never> = Task {}

    public init() {}

    /// Runs `operation` after all previously enqueued work completes.
    /// Throws `Superseded` if a newer operation was enqueued while this one
    /// waited its turn.
    public func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let myGeneration = counter.bump()
        let previousTail = tail

        let task = Task<T, Error> {
            await previousTail.value
            guard self.counter.current <= myGeneration else {
                throw Superseded()
            }
            return try await operation()
        }

        // Keep the chain alive regardless of this task's outcome.
        tail = Task { _ = try? await task.value }

        let value = try await task.value
        return value
    }

    /// Cancels queued work. Running Metal work finishes naturally.
    public func cancelAll() {
        _ = counter.bump()
    }

    /// Enqueues a cache clear as the new tail — never runs mid-generation.
    public func clearCacheWhenIdle(_ clear: @escaping @Sendable () -> Void) {
        let previousTail = tail
        let task = Task<Void, Never> {
            await previousTail.value
            clear()
        }
        tail = task
    }
}
