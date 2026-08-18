import Foundation

/// Multi-model residency for local engines.
///
/// Previously the app was single-resident: loading a second model unloaded
/// the first. The pool keeps several models resident simultaneously — each
/// with its own engine instance and warm KV cache — behind ONE shared
/// `GenerationGate` (MLX permits only one command buffer in flight per
/// process, so resident engines must serialize their Metal work).
///
/// Admission stays with `MemoryAdvisor`: because already-resident models
/// inflate the process footprint, `admitLoad` naturally evaluates a new load
/// against the REMAINING budget. When a load is rejected, the pool evicts
/// least-recently-used idle engines (never the active one) and retries.
///
/// All eviction planning is pure (`Planner`) and unit-testable.
actor EnginePool {

    /// One resident engine plus its residency metadata.
    struct Resident: Sendable {
        var modelID: String
        var directory: URL
        var diskBytes: Int64
        var lastUsed: Date
    }

    /// Pure residency planning — deterministic, no engines involved.
    enum Planner {

        /// Orders eviction candidates: idle (not active) residents, least
        /// recently used first. The active model is never a candidate.
        static func evictionCandidates(
            residents: [Resident],
            activeModelID: String?
        ) -> [Resident] {
            residents
                .filter { $0.modelID != activeModelID }
                .sorted { $0.lastUsed < $1.lastUsed }
        }

        /// Whether the pool may admit one more resident without evicting:
        /// under the residency cap.
        static func underCap(residentCount: Int, maxResident: Int) -> Bool {
            residentCount < maxResident
        }
    }

    // MARK: State

    /// All resident engines share this gate: exactly one command buffer in
    /// flight for the whole process, however many models are loaded.
    private let gate: GenerationGate
    private var engines: [String: any LLMEngine] = [:]
    private var residents: [String: Resident] = [:]
    private(set) var activeModelID: String?
    private let maxResident: Int
    private var engineFactory: @Sendable (GenerationGate) -> any LLMEngine

    /// Test seam: swap the admission authority (tests inject a fixed budget).
    var admitLoad: @Sendable (_ diskBytes: Int64) throws -> Void = { diskBytes in
        try MemoryAdvisor.admitLoad(diskBytes: diskBytes)
    }

    init(gate: GenerationGate = GenerationGate(), maxResident: Int = 4) {
        self.gate = gate
        self.maxResident = maxResident
        self.engineFactory = { gate in MLXEngine(gate: gate) }
    }

    /// Test seam: inject a fake engine factory (deterministic suites never
    /// touch MLX).
    func setEngineFactory(_ factory: @escaping @Sendable (GenerationGate) -> any LLMEngine) {
        engineFactory = factory
    }

    // MARK: Queries

    var residentModelIDs: [String] {
        residents.keys.sorted()
    }

    var isResident: (String) -> Bool {
        { self.residents[$0] != nil }
    }

    func residentInfo(modelID: String) -> Resident? {
        residents[modelID]
    }

    /// The active engine (the one generation routes through).
    private var activeEngine: (any LLMEngine)? {
        guard let activeModelID else { return nil }
        return engines[activeModelID]
    }

    // MARK: Activation

    /// Ensures `modelID` is resident and makes it the active engine.
    /// - Already resident: warm switch — the engine's KV cache survives.
    /// - Not resident: admit against the REMAINING budget, evicting LRU idle
    ///   engines when necessary, then load a fresh engine on the shared gate.
    /// Throws `EngineError` / `MemoryAdvisor.AdmissionError` when the model
    /// cannot be admitted even after evicting every idle resident.
    func activate(directory: URL, modelID: String, diskBytes: Int64) async throws {
        touch(modelID)
        if engines[modelID] != nil {
            activeModelID = modelID
            return
        }

        // Make room: residency cap first, then memory budget. Each eviction
        // frees one model's weights + cache; admission is re-checked after
        // every eviction because the footprint only drops once the kernel
        // reclaims the pages.
        while !Planner.underCap(residentCount: residents.count, maxResident: maxResident)
            || !admissible(diskBytes: diskBytes) {
            guard let victim = Planner.evictionCandidates(
                residents: Array(residents.values), activeModelID: modelID).first
            else { break }
            await evict(modelID: victim.modelID)
        }
        // Final hard admission — never bypass the advisor's safety stops.
        try admitLoad(diskBytes)

        let engine = engineFactory(gate)
        do {
            try await engine.load(directory: directory, modelID: modelID, diskBytes: diskBytes)
        } catch {
            await engine.unload()
            throw error
        }
        engines[modelID] = engine
        residents[modelID] = Resident(
            modelID: modelID, directory: directory, diskBytes: diskBytes, lastUsed: Date())
        activeModelID = modelID
        Log.engine.info("Pool: model \(modelID, privacy: .public) resident (\(self.residents.count) total)")
    }

    /// True when the advisor would admit this load right now.
    private func admissible(diskBytes: Int64) -> Bool {
        (try? admitLoad(diskBytes)) != nil
    }

    /// Unloads and removes one resident engine (LRU eviction path).
    private func evict(modelID: String) async {
        guard let engine = engines[modelID] else { return }
        await engine.unload()
        engines[modelID] = nil
        residents[modelID] = nil
        if activeModelID == modelID {
            activeModelID = nil
        }
        Log.engine.info("Pool: evicted \(modelID, privacy: .public)")
    }

    private func touch(_ modelID: String) {
        residents[modelID]?.lastUsed = Date()
    }

    // MARK: Generation routing

    /// Streams through the active engine. Throws `EngineError.notLoaded`
    /// when nothing is active.
    func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let engine = activeEngine else { throw EngineError.notLoaded }
        touch(activeModelID ?? "")
        return engine.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
    }

    func resetActive() async {
        await activeEngine?.reset()
    }

    func cancelActiveGeneration() async {
        await activeEngine?.cancelGeneration()
    }

    func stats() async -> EngineStats {
        await activeEngine?.stats ?? EngineStats()
    }

    func activeLoadedModelID() async -> String? {
        await activeEngine?.loadedModelID
    }

    // MARK: Lifecycle

    /// Unloads the active model only (other residents stay warm).
    func unloadActive() async {
        guard let modelID = activeModelID, let engine = engines[modelID] else { return }
        await engine.unload()
        engines[modelID] = nil
        residents[modelID] = nil
        activeModelID = nil
    }

    /// Unloads every resident model (app quit / deactivate-all).
    func unloadAll() async {
        for (_, engine) in engines {
            await engine.unload()
        }
        engines.removeAll()
        residents.removeAll()
        activeModelID = nil
    }

    /// Emergency: dump the largest idle resident first (most bytes back),
    /// falling back to the active model. Returns true when something was
    /// actually dumped.
    @discardableResult
    func dumpLargestResident() async -> Bool {
        let candidates = residents.values.sorted { $0.diskBytes > $1.diskBytes }
        // Idle residents first — the active model is the last resort.
        if let victim = candidates.first(where: { $0.modelID != activeModelID }) {
            await evict(modelID: victim.modelID)
            await clearCaches()
            return true
        }
        if let modelID = activeModelID {
            await evict(modelID: modelID)
            await clearCaches()
            return true
        }
        return false
    }

    /// Clears Metal caches across the pool once generation is idle.
    func clearCaches() async {
        // Delegate to whichever engines know their own cache semantics rather
        // than importing MLX here (keeps the pool backend-agnostic).
        await gate.clearCacheWhenIdle {
            // MLX's buffer cache is process-wide; a single clear suffices.
        }
        for (_, engine) in engines {
            await engine.clearCaches()
        }
    }

    /// True when at least one model is resident.
    var hasResidentModels: Bool {
        !residents.isEmpty
    }
}
