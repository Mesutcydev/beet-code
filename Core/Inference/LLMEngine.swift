import Foundation

/// A chat turn as the engine sees it. Engines accumulate the turns they are
/// handed and replay the full conversation per generation (remote APIs are
/// stateless; local engines re-render for context correctness). Call `reset`
/// between unrelated tasks.
public struct ChatTurn: Sendable, Equatable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct EngineStats: Sendable, Equatable {
    public var tokensPerSecond: Double?
    public var generatedTokens: Int
    /// Prompt tokens from the last usage report (0 when the engine doesn't know).
    public var promptTokens: Int
    /// Monotonic id bumped on every completed generation that reported usage.
    /// AppState uses this to accumulate session totals without double-counting
    /// the 2-second stats poll.
    public var usageSerial: UInt64

    public init(
        tokensPerSecond: Double? = nil,
        generatedTokens: Int = 0,
        promptTokens: Int = 0,
        usageSerial: UInt64 = 0
    ) {
        self.tokensPerSecond = tokensPerSecond
        self.generatedTokens = generatedTokens
        self.promptTokens = promptTokens
        self.usageSerial = usageSerial
    }
}

public enum EngineError: Error, LocalizedError, Equatable {
    case notLoaded
    case alreadyLoading
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "No model is loaded."
        case .alreadyLoading: return "A model load is already in progress."
        case .loadFailed(let reason): return "Model failed to load: \(reason)"
        }
    }
}

/// Abstraction over inference backends. Today: MLX. Later: a GGUF/llama.cpp
/// engine behind the same protocol.
public protocol LLMEngine: AnyObject, Sendable {
    var loadedModelID: String? { get async }
    var stats: EngineStats { get async }

    /// The context window actually in effect for the resident model, when
    /// the engine knows it. GGUF fits the llama-server launch ctx to the RAM
    /// budget, which can be SMALLER than the catalog window — the agent
    /// loop's compaction must target this number or the server hard-errors
    /// (HTTP 400) instead of compacting. nil → fall back to the catalog.
    /// A protocol REQUIREMENT (default below) for the same dispatch reason
    /// as the context-aware load.
    var effectiveContextWindow: Int? { get async }

    /// Loads a model from a local directory. Admission is arbitrated by
    /// `MemoryAdvisor` before any weights are touched.
    func load(directory: URL, modelID: String, diskBytes: Int64) async throws

    /// Context-window-aware load. A protocol REQUIREMENT (with the default
    /// below) so calls through `any LLMEngine` dispatch to the conformer's
    /// witness — GGUFEngine's llama-server needs the size as a launch flag,
    /// and an extension-only member would be statically bypassed.
    func load(directory: URL, modelID: String, diskBytes: Int64, contextSize: Int?) async throws

    func unload() async

    func reset() async

    /// Appends turns to the session and streams the model's reply as text
    /// chunks. `maxTokens` caps this generation (thermal policy applied by
    /// the caller).
    func stream(adding turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error>

    /// Generate from an explicit transcript WITHOUT mutating the engine's
    /// resident conversation. Used by nested `task` subagents so the parent
    /// turn history / KV accumulation stays intact. Default: `stream(adding:)`.
    func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error>

    /// Cancels queued/in-flight generation. In-flight Metal work completes;
    /// queued work is skipped.
    func cancelGeneration() async
}

extension LLMEngine {
    /// Memory-pressure response: free caches. Default: nothing (engines that
    /// maintain caches override this).
    func clearCaches() async {}

    /// Default context-aware load: engines that size context from the model
    /// itself (MLX reads the checkpoint config) ignore the hint. Public —
    /// witnesses for a public protocol must be.
    public func load(directory: URL, modelID: String, diskBytes: Int64, contextSize: Int?) async throws {
        try await load(directory: directory, modelID: modelID, diskBytes: diskBytes)
    }

    /// Default: the engine doesn't size context itself — callers use the
    /// catalog window. Public — witnesses for a public protocol must be.
    public var effectiveContextWindow: Int? { get async { nil } }

    public func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
    }

    /// Emergency unload used by the memory-pressure coordinator. Returns true
    /// when a model was actually resident and got dumped.
    @discardableResult
    func dumpIfResident() async -> Bool { false }
}
