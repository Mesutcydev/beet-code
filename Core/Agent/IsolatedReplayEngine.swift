import Foundation

/// Wraps a parent engine so a nested `task` subagent can generate without
/// resetting or appending to the parent's resident conversation.
///
/// `reset()` only clears this wrapper. `stream(adding:)` accumulates locally
/// and calls `streamReplay` on the base engine.
final class IsolatedReplayEngine: LLMEngine, @unchecked Sendable {
    private let base: any LLMEngine
    private let lock = NSLock()
    private var own: [ChatTurn] = []

    init(base: any LLMEngine) {
        self.base = base
    }

    var loadedModelID: String? {
        get async { await base.loadedModelID }
    }

    var stats: EngineStats {
        get async { await base.stats }
    }

    var effectiveContextWindow: Int? {
        get async { await base.effectiveContextWindow }
    }

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        try await base.load(directory: directory, modelID: modelID, diskBytes: diskBytes)
    }

    func unload() async {
        // Never unload the parent's resident model.
    }

    func reset() async {
        withLock { own.removeAll() }
    }

    func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        let all = withLock { () -> [ChatTurn] in
            own.append(contentsOf: turns)
            return own
        }
        return base.streamReplay(all, maxTokens: maxTokens, temperature: temperature)
    }

    func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        base.streamReplay(turns, maxTokens: maxTokens, temperature: temperature)
    }

    func cancelGeneration() async {
        await base.cancelGeneration()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
