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

    private let gate: GenerationGate

    /// Engines created with a shared gate (the EnginePool) serialize their
    /// Metal work with every other resident model — MLX permits only one
    /// command buffer in flight per process, regardless of how many models
    /// are resident. Standalone engines own their gate.
    public init(gate: GenerationGate = GenerationGate()) {
        self.gate = gate
    }

    // Only accessed inside gate.run closures. `nonisolated(unsafe)` documents
    // that the gate — not the type system — guarantees exclusive access.
    private nonisolated(unsafe) var session: ChatSession?
    private nonisolated(unsafe) var loadedID: String?
    private nonisolated(unsafe) var statsState = EngineStats()
    private nonisolated(unsafe) var loading = false
    /// The active stream task. Retaining it lets Stop cancel the running
    /// generation instead of only invalidating queued gate work.
    private nonisolated(unsafe) var generationTask: Task<Void, Never>?
    private nonisolated(unsafe) var generationID: UUID?
    private let generationLock = NSLock()
    /// Conversation replayed in full on every generation. ChatSession's KV
    /// reuse across calls is deliberately NOT used: the agent loop re-feeds
    /// assistant turns the session already generated (thinking-stripped), so
    /// incremental rendering would duplicate content and corrupt the chat
    /// template. Full replay — the same contract the remote and GGUF engines
    /// implement — keeps the context provably correct at the cost of a
    /// re-prefill per turn.
    private nonisolated(unsafe) var history: [ChatTurn] = []

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
                MLX.Memory.cacheLimit = 128 * 1024 * 1024

                self.session = ChatSession(
                    container,
                    generateParameters: MLXEngine.makeParameters(temperature: 0.6, maxTokens: nil))
                self.loadedID = modelID
                self.statsState = EngineStats()
                self.history.removeAll()

                // Do not synchronously page the whole model during activation.
                // On larger Apple Silicon models this can keep the composer in
                // "Loading" for minutes (or appear hung while Metal faults in
                // every weight). MLX will page the weights on the first
                // generation; activation should become ready once the session
                // exists so the user can see and cancel a real first turn.
                Log.engine.info(
                    "Model session ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s — weights page on first generation; footprint \(MemoryAdvisor.processFootprint / 1_000_000) MB")
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
            self.history.removeAll()
            await self.session?.clear()
        }
    }

    public func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let generationTask = Task {
                defer { self.clearGenerationTask(id: id) }
                do {
                    try await self.gate.run {
                        guard let session = self.session else { throw EngineError.notLoaded }

                        // Full replay (see `history`): fresh KV, complete
                        // conversation rendered through the chat template.
                        self.history.append(contentsOf: turns)
                        await session.clear()

                        let messages = self.history.map { turn -> Chat.Message in
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
                        // streamDetails, NOT streamResponse: MLXLMCommon parses
                        // `<tool_call>` blocks (and bare {"name":…} JSON) into
                        // `.toolCall` generations whose `chunk` is nil —
                        // streamResponse drops them silently, so the agent's
                        // ToolParser never saw local tool calls at all. Here
                        // they are re-serialized into the wire text the
                        // ToolParser recognizes.
                        for try await generation in session.streamDetails(to: messages) {
                            if Task.isCancelled { break }
                            switch generation {
                            case .chunk(let chunk):
                                continuation.yield(chunk)
                                tokens += 1
                            case .toolCall(let call):
                                continuation.yield(MLXEngine.serializeToolCall(call))
                            case .info:
                                break
                            }
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
            self.setGenerationTask(generationTask, id: id)
            continuation.onTermination = { _ in
                generationTask.cancel()
                self.clearGenerationTask(id: id)
            }
        }
    }

    public func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let saved = (try? await self.gate.run { () -> [ChatTurn] in
                    let old = self.history
                    self.history = []
                    return old
                }) ?? []
                do {
                    let inner = self.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
                    for try await chunk in inner {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                _ = try? await self.gate.run { self.history = saved }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancelGeneration() async {
        let task = withGenerationLock { generationTask }
        task?.cancel()
        await gate.cancelAll()
    }

    private func setGenerationTask(_ task: Task<Void, Never>, id: UUID) {
        generationLock.lock()
        generationTask = task
        generationID = id
        generationLock.unlock()
    }

    private func clearGenerationTask(id: UUID) {
        generationLock.lock()
        if generationID == id {
            generationTask = nil
            generationID = nil
        }
        generationLock.unlock()
    }

    private func withGenerationLock<T>(_ body: () -> T) -> T {
        generationLock.lock()
        defer { generationLock.unlock() }
        return body()
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
        // Qwen-recommended sampling for the local catalog: nucleus + top-k
        // with a light repetition penalty keeps small 4-bit models off the
        // rambling/repetition tails that plain temperature sampling invites
        // (defaults are topP 1.0 / topK 0 — unbounded).
        if temperature > 0 {
            params.topP = 0.95
            params.topK = 20
            params.repetitionPenalty = 1.05
        }
        params.maxTokens = maxTokens
        return params
    }

    /// Re-serializes a parsed tool call into the `<tool_call>` wire text the
    /// agent's `ToolParser` recognizes (the inverse of parsing — see
    /// `ToolCallText`).
    private static func serializeToolCall(_ call: ToolCall) -> String {
        let object = call.function.arguments.mapValues { $0.anyValue }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let argumentsJSON = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolCallText.serialize(name: call.function.name, argumentsJSON: argumentsJSON)
    }
}
