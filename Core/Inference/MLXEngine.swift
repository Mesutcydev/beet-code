import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// MLX-backed engine. Runs in-process on the app's own GPU context.
///
/// All `ChatSession`/Metal access is funneled through `GenerationGate` —
/// `session` is only ever touched inside `gate.run { }` closures, which are
/// serialized. That is what keeps concurrent command buffers (a process-
/// killing MLX crash) impossible by construction.
public final class MLXEngine: LLMEngine, @unchecked Sendable {

    private let gate = GenerationGate()

    // Only accessed inside gate.run closures. `nonisolated(unsafe)` documents
    // that the gate — not the type system — guarantees exclusive access.
    private nonisolated(unsafe) var session: ChatSession?
    private nonisolated(unsafe) var loadedID: String?
    private nonisolated(unsafe) var statsState = EngineStats()
    private nonisolated(unsafe) var loading = false

    public init() {}

    public var loadedModelID: String? {
        get async { try? await gate.run { self.loadedID } }
    }

    public var stats: EngineStats {
        get async { (try? await gate.run { self.statsState }) ?? EngineStats() }
    }

    public func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        // MemoryAdvisor is the single admission authority — engines never
        // second-guess it.
        try MemoryAdvisor.admitLoad(diskBytes: diskBytes)

        try await gate.run {
            guard !self.loading else { throw EngineError.alreadyLoading }
            self.loading = true
            defer { self.loading = false }

            do {
                Log.engine.info("Loading model \(modelID, privacy: .public)")
                let started = Date()

                let container = try await LLMModelFactory.shared.loadContainer(
                    from: directory,
                    using: HFTokenizerLoader())

                // Keep the Metal buffer cache modest: weights are memory-mapped
                // and paged in on demand; a large cache would double-count RAM.
                MLX.GPU.set(cacheLimit: 128 * 1024 * 1024)

                self.session = ChatSession(
                    container,
                    generateParameters: MLXEngine.makeParameters(temperature: 0.6, maxTokens: nil))
                self.loadedID = modelID
                self.statsState = EngineStats()

                // Page the weights in now so the first token isn't slow.
                try await self.session?.synchronize()
                Log.engine.info(
                    "Model loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s — footprint \(MemoryAdvisor.processFootprint / 1_000_000) MB")
            } catch {
                self.session = nil
                self.loadedID = nil
                throw EngineError.loadFailed(String(describing: error))
            }
        }
    }

    public func unload() async {
        _ = try? await gate.run {
            self.session = nil
            self.loadedID = nil
            self.statsState = EngineStats()
        }
        await gate.clearCacheWhenIdle {
            MLX.Memory.clearCache()
        }
    }

    public func reset() async {
        _ = try? await gate.run {
            await self.session?.clear()
        }
    }

    public func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let generationTask = Task {
                do {
                    try await self.gate.run {
                        guard let session = self.session else { throw EngineError.notLoaded }

                        let messages = turns.map { turn -> Chat.Message in
                            switch turn.role {
                            case .system: return Chat.Message.system(turn.content)
                            case .user: return Chat.Message.user(turn.content)
                            case .assistant: return Chat.Message.assistant(turn.content)
                            case .tool: return Chat.Message.tool(turn.content)
                            }
                        }

                        session.generateParameters = MLXEngine.makeParameters(
                            temperature: temperature ?? 0.6,
                            maxTokens: maxTokens)

                        var tokens = 0
                        let started = Date()
                        for try await chunk in session.streamResponse(to: messages) {
                            if Task.isCancelled { break }
                            continuation.yield(chunk)
                            tokens += 1
                        }

                        let elapsed = Date().timeIntervalSince(started)
                        if elapsed > 0.2 {
                            self.statsState = EngineStats(
                                tokensPerSecond: Double(tokens) / elapsed,
                                generatedTokens: tokens)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                generationTask.cancel()
            }
        }
    }

    public func cancelGeneration() async {
        await gate.cancelAll()
    }

    /// Frees Metal buffer cache once any in-flight generation finishes.
    public func clearCaches() async {
        await gate.clearCacheWhenIdle {
            MLX.Memory.clearCache()
        }
    }

    /// Emergency unload path used by the memory-pressure coordinator. Returns
    /// true when a model was actually resident and got dumped.
    @discardableResult
    public func dumpIfResident() async -> Bool {
        let wasLoaded: String? = (try? await gate.run {
            let id = self.loadedID
            self.session = nil
            self.loadedID = nil
            self.statsState = EngineStats()
            return id
        }) ?? nil
        if wasLoaded != nil {
            await gate.clearCacheWhenIdle { MLX.Memory.clearCache() }
            Log.memory.warning("Resident model dumped by memory pressure")
        }
        return wasLoaded != nil
    }

    private static func makeParameters(temperature: Double, maxTokens: Int?) -> GenerateParameters {
        var params = GenerateParameters()
        params.temperature = Float(temperature)
        params.maxTokens = maxTokens
        return params
    }
}
