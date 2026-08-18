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

    public init(tokensPerSecond: Double? = nil, generatedTokens: Int = 0) {
        self.tokensPerSecond = tokensPerSecond
        self.generatedTokens = generatedTokens
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

    /// Loads a model from a local directory. Admission is arbitrated by
    /// `MemoryAdvisor` before any weights are touched.
    func load(directory: URL, modelID: String, diskBytes: Int64) async throws

    func unload() async

    func reset() async

    /// Appends turns to the session and streams the model's reply as text
    /// chunks. `maxTokens` caps this generation (thermal policy applied by
    /// the caller).
    func stream(adding turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error>

    /// Cancels queued/in-flight generation. In-flight Metal work completes;
    /// queued work is skipped.
    func cancelGeneration() async
}

extension LLMEngine {
    /// Memory-pressure response: free caches. Default: nothing (engines that
    /// maintain caches override this).
    func clearCaches() async {}

    /// Emergency unload used by the memory-pressure coordinator. Returns true
    /// when a model was actually resident and got dumped.
    @discardableResult
    func dumpIfResident() async -> Bool { false }
}
