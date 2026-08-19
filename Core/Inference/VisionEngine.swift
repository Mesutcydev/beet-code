import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// Local vision sidecar: runs a SmolVLM2 (MLX VLM) model in-process to
/// describe image attachments and simulator screenshots.
///
/// Shares the LLM engines' `GenerationGate` — MLX permits only one command
/// buffer in flight per process, so the VLM's Metal work must serialize with
/// every other resident model. The gate is injected at app start from the
/// EnginePool; without injection a private gate is used (tests, CLI).
///
/// Residency is deliberately simple: the first describe loads the model and
/// keeps it warm (a coding agent describes screenshots repeatedly); RAM
/// admission goes through `MemoryAdvisor` like any other load, and
/// `unload()` is wired into the memory-pressure path via `dumpIfResident()`.
final class VisionEngine: @unchecked Sendable {

    static let shared = VisionEngine()

    private let lock = NSLock()
    /// Only touched under `lock` (identity/load bookkeeping) or inside
    /// gate.run closures (the container/session itself).
    private var gate: GenerationGate?
    private nonisolated(unsafe) var session: ChatSession?
    private var loadedModelID: String?
    private var loading = false

    private init() {}

    /// Called once at app start with the EnginePool's shared gate.
    func configure(gate: GenerationGate) {
        lock.withLock { self.gate = gate }
    }

    private func currentGate() -> GenerationGate {
        lock.withLock {
            if let gate { return gate }
            let fallback = GenerationGate()
            gate = fallback
            return fallback
        }
    }

    /// ID of the resident vision model, if any (diagnostics).
    var residentModelID: String? {
        lock.withLock { loadedModelID }
    }

    enum VisionEngineError: Error, LocalizedError {
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let reason): return "Vision model failed to load: \(reason)"
            }
        }
    }

    /// Loads the VLM from a local directory if it isn't already resident.
    /// Admission is arbitrated by `MemoryAdvisor` before weights are touched.
    private func ensureLoaded(directory: URL, modelID: String, diskBytes: Int64) async throws {
        if lock.withLock({ loadedModelID }) == modelID { return }
        try MemoryAdvisor.admitLoad(diskBytes: diskBytes)

        let gate = currentGate()
        try await gate.run {
            let alreadyLoaded = self.lock.withLock { self.loadedModelID }
            guard alreadyLoaded != modelID else { return }
            let alreadyLoading = self.lock.withLock { () -> Bool in
                if self.loading { return true }
                self.loading = true
                return false
            }
            guard !alreadyLoading else { throw EngineError.alreadyLoading }
            defer { self.lock.withLock { self.loading = false } }

            do {
                Log.engine.info("Loading vision model \(modelID, privacy: .public)")
                let started = Date()
                let container = try await VLMModelFactory.shared.loadContainer(
                    from: directory,
                    using: HFTokenizerLoader())
                // Same discipline as MLXEngine: weights are memory-mapped, a
                // big Metal cache would double-count RAM.
                MLX.Memory.cacheLimit = 128 * 1024 * 1024
                self.session = ChatSession(container)
                self.lock.withLock { self.loadedModelID = modelID }
                await self.session?.synchronize()
                Log.engine.info(
                    "Vision model loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            } catch {
                self.session = nil
                self.lock.withLock { self.loadedModelID = nil }
                throw VisionEngineError.loadFailed(String(describing: error))
            }
        }
    }

    /// Describes an image with the given (already downloaded) vision model.
    func describe(
        imageAt imageURL: URL,
        prompt: String,
        model: CatalogModel,
        directory: URL,
        diskBytes: Int64
    ) async throws -> String {
        try await ensureLoaded(directory: directory, modelID: model.id, diskBytes: diskBytes)
        let gate = currentGate()
        return try await gate.run {
            guard let session = self.session else { throw EngineError.notLoaded }
            // One-shot: a fresh ChatSession per call keeps no conversational
            // state — each describe is independent (and cheaper than paying
            // KV replay for a sidecar).
            return try await session.respond(
                to: prompt,
                image: .url(imageURL))
        }
    }

    func unload() async {
        let gate = currentGate()
        _ = try? await gate.run {
            self.session = nil
            self.lock.withLock { self.loadedModelID = nil }
        }
        await gate.clearCacheWhenIdle {
            MLX.Memory.clearCache()
        }
    }

    /// Memory-pressure response, same contract as the LLM engines.
    @discardableResult
    func dumpIfResident() async -> Bool {
        let resident = lock.withLock { loadedModelID != nil }
        if resident { await unload() }
        return resident
    }
}
