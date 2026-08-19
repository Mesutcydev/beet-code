import Foundation

/// LLMEngine implementation backed by a BYOK remote provider. History is
/// replayed per call (no KV cache server-side), so reset is a no-op and
/// stream(adding:) sends the full conversation.
final class RemoteLLMEngine: LLMEngine, @unchecked Sendable {

    let endpoint: RemoteEndpoint
    private let apiKey: String
    private let lock = NSLock()
    private var generationTask: Task<Void, Never>?
    private var statsState = EngineStats()
    /// Remote APIs are stateless — there is no server-side KV cache — so the
    /// engine accumulates every turn it is handed and replays the FULL
    /// conversation on each call. `reset()` clears the accumulation (the loop
    /// calls it at task start and after compaction rebuilds history).
    private var accumulated: [ChatTurn] = []

    init?(endpoint: RemoteEndpoint) {
        // Custom/local servers may run without auth; every other provider
        // requires a Keychain key.
        let key = APIKeyStore.key(provider: endpoint.provider)
        if key == nil && !endpoint.provider.keyOptional { return nil }
        self.endpoint = endpoint
        self.apiKey = key ?? ""
    }

    var loadedModelID: String? {
        get async { endpoint.provider.rawValue + ":" + endpoint.model }
    }

    var stats: EngineStats {
        get async { withLock { statsState } }
    }

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        // Remote engines have nothing to load; presence of key+endpoint was
        // validated at init.
    }

    func unload() async {}

    func reset() async {
        withLock { accumulated.removeAll() }
    }

    func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        // Stateless replay: append the new turns, then send the entire
        // accumulated conversation. Sending only the delta (what the local
        // KV-cached engine expects) would leave the remote model without any
        // context after the first turn.
        let allTurns = withLock { () -> [ChatTurn] in
            accumulated.append(contentsOf: turns)
            return accumulated
        }

        let usageBox = UsageBox()
        let onUsage: @Sendable (RemoteLLMClient.UsageInfo) -> Void = { [weak self] usage in
            usageBox.last = usage
            self?.noteUsage(usage, startedAt: usageBox.started)
        }

        let stream: AsyncThrowingStream<String, Error>
        if endpoint.provider == .anthropic,
           let base = endpoint.provider.anthropicBaseURL {
            stream = RemoteLLMClient.streamAnthropic(
                baseURL: base,
                apiKey: self.apiKey,
                model: endpoint.model,
                turns: allTurns,
                temperature: temperature,
                maxTokens: maxTokens,
                onUsage: onUsage)
        } else if endpoint.provider == .gemini,
                  let base = endpoint.provider.geminiBaseURL {
            stream = RemoteLLMClient.streamGemini(
                baseURL: base,
                apiKey: self.apiKey,
                model: endpoint.model,
                turns: allTurns,
                temperature: temperature,
                maxTokens: maxTokens,
                onUsage: onUsage)
        } else if let base = endpoint.provider.openAICompatibleBaseURL {
            stream = RemoteLLMClient.streamOpenAICompatible(
                provider: endpoint.provider,
                baseURL: base,
                apiKey: self.apiKey,
                model: endpoint.model,
                turns: allTurns,
                temperature: temperature,
                maxTokens: maxTokens,
                onUsage: onUsage)
        } else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: RemoteLLMError.invalidConfiguration(
                    endpoint.provider == .custom
                        ? "No custom base URL configured — set one in Settings → BYOK Providers → Custom."
                        : "no endpoint URL"))
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var tokens = 0
                let started = Date()
                do {
                    for try await chunk in stream {
                        if Task.isCancelled {
                            continuation.finish(throwing: RemoteLLMError.cancelled)
                            return
                        }
                        continuation.yield(chunk)
                        tokens += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                // Usage callback (real token counts) already updated stats
                // when the provider reported them; fall back to chunk-count
                // stats only when no usage arrived (P9 truthfulness).
                let elapsed = Date().timeIntervalSince(started)
                if elapsed > 0.2, usageBox.last == nil {
                    self.updateStats(EngineStats(
                        tokensPerSecond: Double(tokens) / elapsed,
                        generatedTokens: tokens))
                }
            }
            self.setGenerationTask(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Real usage accounting (P9): the provider reports completion tokens;
    /// tok/s uses wall time since stream start.
    private func noteUsage(_ usage: RemoteLLMClient.UsageInfo, startedAt: Date) {
        guard let completion = usage.completionTokens, completion > 0 else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        updateStats(EngineStats(
            tokensPerSecond: elapsed > 0 ? Double(completion) / elapsed : nil,
            generatedTokens: completion))
    }

    /// Per-run usage state shared between the stream closure and callbacks.
    private final class UsageBox: @unchecked Sendable {
        var last: RemoteLLMClient.UsageInfo?
        let started = Date()
    }

    func cancelGeneration() async {
        let task = withLock { () -> Task<Void, Never>? in
            let current = generationTask
            generationTask = nil
            return current
        }
        task?.cancel()
    }

    private func setGenerationTask(_ task: Task<Void, Never>?) {
        lock.lock()
        generationTask = task
        lock.unlock()
    }

    private func updateStats(_ stats: EngineStats) {
        lock.lock()
        statsState = stats
        lock.unlock()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Routes engine requests to either the local MLX engine or the active BYOK
/// remote endpoint. AppState holds one router; switching providers swaps the
/// delegate without touching the agent or UI layers.
final class EngineRouter: LLMEngine, @unchecked Sendable {

    enum Source: Equatable {
        case localMLX
        case remote(RemoteEndpoint)
    }

    private let lock = NSLock()
    /// The multi-resident local engine pool. When present, local loads keep
    /// previously-loaded models warm instead of unloading them; generation
    /// routes through the pool's active engine on the shared Metal gate.
    /// nil → legacy single-resident path (test doubles).
    private let pool: EnginePool?
    private let local: any LLMEngine
    private var currentRemote: RemoteLLMEngine?
    private(set) var source: Source = .localMLX
    private var activeLocalID: String?

    init(local: any LLMEngine = MLXEngine(), pool: EnginePool? = nil) {
        self.local = local
        self.pool = pool
    }

    /// The pool (when the router runs pooled) — exposed for AppState and the
    /// memory-pressure coordinator.
    var enginePool: EnginePool? { pool }

    var activeRemoteEndpoint: RemoteEndpoint? {
        withLock { currentRemote?.endpoint }
    }

    @discardableResult
    func useRemote(_ endpoint: RemoteEndpoint) -> Bool {
        guard let remote = RemoteLLMEngine(endpoint: endpoint) else { return false }
        withLock {
            currentRemote = remote
            source = .remote(endpoint)
        }
        return true
    }

    func useLocal() {
        withLock {
            currentRemote = nil
            source = .localMLX
        }
    }

    var loadedModelID: String? {
        get async {
            if let remote = withLock({ currentRemote }) { return await remote.loadedModelID }
            if let pool { return await pool.activeLoadedModelID() }
            return await local.loadedModelID
        }
    }

    var effectiveContextWindow: Int? {
        get async {
            if withLock({ currentRemote }) != nil { return nil }
            if let pool { return await pool.activeEffectiveContextWindow() }
            return await local.effectiveContextWindow
        }
    }

    var stats: EngineStats {
        get async {
            if let remote = withLock({ currentRemote }) { return await remote.stats }
            if let pool { return await pool.stats() }
            return await local.stats
        }
    }

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        try await load(directory: directory, modelID: modelID, diskBytes: diskBytes, format: .mlx)
    }

    /// Format-aware load: the pool instantiates the right engine (MLX
    /// in-process vs GGUF llama-server) per model. `contextSize` is the
    /// catalog's context window — only the GGUF server needs it as a flag.
    func load(directory: URL, modelID: String, diskBytes: Int64, format: CatalogModel.Format, contextSize: Int? = nil) async throws {
        if let pool {
            // Multi-resident: keeps other loaded models warm, evicting LRU
            // idle residents only when the memory budget requires it.
            try await pool.activate(directory: directory, modelID: modelID, diskBytes: diskBytes, format: format, contextSize: contextSize)
            return
        }
        try await local.load(directory: directory, modelID: modelID, diskBytes: diskBytes, contextSize: contextSize)
    }

    func unload() async {
        if let pool {
            // Pool semantics: only the ACTIVE model unloads; other residents
            // stay warm until memory pressure or the cap evicts them.
            await pool.unloadActive()
            return
        }
        await local.unload()
    }

    func reset() async {
        if let remote = withLock({ currentRemote }) {
            await remote.reset()
        } else if let pool {
            await pool.resetActive()
        } else {
            await local.reset()
        }
    }

    func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        if let remote = withLock({ currentRemote }) {
            return remote.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
        }
        if let pool {
            // The pool is an actor: resolve the active engine with a hop,
            // then relay the inner stream chunk-by-chunk.
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let inner = try await pool.stream(
                            adding: turns, maxTokens: maxTokens, temperature: temperature)
                        for try await chunk in inner {
                            if Task.isCancelled { break }
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return local.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
    }

    func cancelGeneration() async {
        if let remote = withLock({ currentRemote }) {
            await remote.cancelGeneration()
        } else if let pool {
            await pool.cancelActiveGeneration()
        } else {
            await local.cancelGeneration()
        }
    }

    func clearCaches() async {
        if let pool {
            await pool.clearCaches()
        } else {
            await local.clearCaches()
        }
    }

    @discardableResult
    func dumpIfResident() async -> Bool {
        if let pool {
            return await pool.dumpLargestResident()
        }
        return await local.dumpIfResident()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}