import Foundation

/// Remote LLM providers supported by the BYOK (bring-your-own-key) engine.
/// Most are OpenAI-compatible chat-completions APIs; Gemini and Anthropic
/// use their native formats; `custom` lets the user point at ANY
/// OpenAI-compatible server (Ollama, LM Studio, vLLM, Groq, proxies…).
enum LLMProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case openAI
    case deepSeek
    case longCat
    case alibaba
    case alibabaTokenPlan
    case gemini
    case openRouter
    case openCode
    case anthropic
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .longCat: "LongCat"
        case .alibaba: "Alibaba (DashScope)"
        case .alibabaTokenPlan: "Alibaba Token Plan"
        case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"
        case .openCode: "OpenCode"
        case .anthropic: "Anthropic"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    /// Base URL for OpenAI-compatible endpoints (nil for native-API providers
    /// and for `custom` until the user configures one).
    var openAICompatibleBaseURL: URL? {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1")
        case .deepSeek: URL(string: "https://api.deepseek.com/v1")
        // LongCat's current OpenAI-compatible surface is hosted under the
        // `/openai` prefix; the old api.longcat.ai/v1 route no longer serves
        // the platform API.
        case .longCat: URL(string: "https://api.longcat.chat/openai/v1")
        case .alibaba: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        case .alibabaTokenPlan: URL(string: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1")
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")
        case .openCode: URL(string: "https://opencode.ai/zen/v1")
        case .custom: Self.configuredCustomBaseURL()
        case .gemini, .anthropic: nil
        }
    }

    /// User-configured base URL for the custom provider (e.g.
    /// `http://127.0.0.1:11434/v1` for Ollama). Kept in preferences, not
    /// Keychain — it's not a secret.
    static func configuredCustomBaseURL() -> URL? {
        guard let raw = AppPreferencesStore.shared.current.customBaseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else { return nil }
        return url
    }

    /// Explicit model-list route for providers whose chat and catalog bases
    /// differ. Keeping this beside the provider definition prevents Settings,
    /// the connection test, and the engine from silently drifting apart.
    var modelsURL: URL? {
        switch self {
        case .gemini:
            return geminiBaseURL?.appendingPathComponent("models")
        case .anthropic:
            return anthropicBaseURL?.appendingPathComponent("models")
        default:
            return openAICompatibleBaseURL?.appendingPathComponent("models")
        }
    }

    /// Gemini native base (models and streamGenerateContent endpoints).
    var geminiBaseURL: URL? {
        self == .gemini ? URL(string: "https://generativelanguage.googleapis.com/v1beta") : nil
    }

    /// Anthropic Messages API base.
    var anthropicBaseURL: URL? {
        self == .anthropic ? URL(string: "https://api.anthropic.com/v1") : nil
    }

    var supportsVision: Bool {
        switch self {
        case .openAI, .gemini, .openRouter: true
        case .deepSeek, .longCat, .alibaba, .alibabaTokenPlan, .openCode, .anthropic, .custom: false
        }
    }

    /// Sensible default model IDs for each provider.
    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .deepSeek: "deepseek-chat"
        case .longCat: "LongCat-2.0"
        case .alibaba: "qwen-plus"
        case .alibabaTokenPlan: "qwen3.8-max"
        case .gemini: "gemini-3.7-flash"
        case .openRouter: "openrouter/auto"
        case .openCode: "big-pickle"
        case .anthropic: "claude-sonnet-4-5"
        case .custom: ""  // user must type the model id served by their endpoint
        }
    }

    /// Model presets offered in the BYOK settings UI.
    /// Static fallback model list — shown before a live `/v1/models` fetch
    /// succeeds. Keep to the CURRENT generation; the live fetch (triggered
    /// automatically when a key is saved) is the source of truth.
    var suggestedModels: [String] {
        switch self {
        case .openAI: ["gpt-5.2", "gpt-5", "gpt-5-mini", "gpt-4.1"]
        case .deepSeek: ["deepseek-chat", "deepseek-reasoner"]
        case .longCat: ["LongCat-2.0"]
        case .alibaba: ["qwen-plus", "qwen-max", "qwen-turbo"]
        case .alibabaTokenPlan: ["qwen3.8-max", "qwen3.7-max", "qwen3.7-plus", "qwen3.6-flash", "deepseek-v4-pro", "deepseek-v4-flash-0731", "glm-5.2"]
        case .gemini: ["gemini-3.7-flash", "gemini-2.5-flash", "gemini-2.5-pro"]
        case .openRouter: ["anthropic/claude-sonnet-4.6", "anthropic/claude-sonnet-4.5", "openai/gpt-5"]
        case .openCode: ["big-pickle", "grok-4.5", "minimax-m2.5-free", "glm-5.1"]
        case .anthropic: ["claude-opus-4-6", "claude-sonnet-4-6", "claude-sonnet-4-5"]
        case .custom: []
        }
    }

    /// Keychain service name for this provider's API key.
    var keychainService: String { "com.beetcode.provider.\(rawValue)" }

    /// Custom/local servers often run without auth (Ollama, LM Studio).
    var keyOptional: Bool { self == .custom }
}

/// A configured remote endpoint: provider + model choice.
struct RemoteEndpoint: Codable, Sendable, Equatable {
    var provider: LLMProvider
    var model: String
}

/// Capability metadata for one remote model. Providers often expose only an
/// id, so every field is optional and can be completed by a user override.
/// This keeps context sizing and tool/reasoning decisions explicit instead of
/// relying on increasingly fragile model-name heuristics.
struct RemoteModelProfile: Codable, Sendable, Equatable, Identifiable {
    var provider: LLMProvider
    var model: String
    var displayName: String?
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var supportsVision: Bool?
    var supportsTools: Bool?
    var supportsReasoning: Bool?
    var supportsTemperature: Bool?

    var id: String { "\(provider.rawValue):\(model)" }

    init(
        provider: LLMProvider,
        model: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsVision: Bool? = nil,
        supportsTools: Bool? = nil,
        supportsReasoning: Bool? = nil,
        supportsTemperature: Bool? = nil
    ) {
        self.provider = provider
        self.model = model
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.supportsTemperature = supportsTemperature
    }

    func applying(_ override: RemoteModelOverride?) -> RemoteModelProfile {
        guard let override else { return self }
        var result = self
        if let value = override.contextWindow { result.contextWindow = value }
        if let value = override.maxOutputTokens { result.maxOutputTokens = value }
        if let value = override.supportsVision { result.supportsVision = value }
        if let value = override.supportsTools { result.supportsTools = value }
        if let value = override.supportsReasoning { result.supportsReasoning = value }
        if let value = override.supportsTemperature { result.supportsTemperature = value }
        return result
    }
}

/// Optional per-model overrides persisted in the project-independent
/// preferences file. No credential or endpoint secret is stored here.
struct RemoteModelOverride: Codable, Sendable, Equatable {
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var supportsVision: Bool?
    var supportsTools: Bool?
    var supportsReasoning: Bool?
    var supportsTemperature: Bool?

    init(
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsVision: Bool? = nil,
        supportsTools: Bool? = nil,
        supportsReasoning: Bool? = nil,
        supportsTemperature: Bool? = nil
    ) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.supportsTemperature = supportsTemperature
    }

    var isEmpty: Bool {
        contextWindow == nil && maxOutputTokens == nil && supportsVision == nil
            && supportsTools == nil && supportsReasoning == nil
            && supportsTemperature == nil
    }
}

/// Keychain-backed storage for provider API keys. Keys are credentials —
/// they never touch UserDefaults or the session files.
@MainActor
final class APIKeyStore: ObservableObject {

    static let shared = APIKeyStore()

    // Keys are cached in memory after the first Keychain read: at launch the
    // UI may probe every provider, and each raw SecItem access can trigger a
    // keychain password prompt on ad-hoc-signed builds.
    nonisolated private static let cacheLock = NSLock()
    // Only one first read may cross into securityd at a time. This prevents
    // several SwiftUI provider cards from opening duplicate authorization
    // requests before the in-memory cache is populated.
    nonisolated private static let keyReadLock = NSLock()
    // All access happens under cacheLock, which is what makes this safe.
    nonisolated(unsafe) private static var keyCache: [LLMProvider: String?] = [:]
    nonisolated(unsafe) private static var configuredHintCache: Set<LLMProvider>?
    nonisolated private static let configuredHintDefaultsKey = "beetcode.configured-provider-hints"

    init() {
        // Deliberately no Keychain access here — providers are probed
        // lazily through key(for:) and cached.
    }

    /// Thread-safe key read for background engines; caches after first read.
    nonisolated static func key(provider: LLMProvider) -> String? {
        keyReadLock.lock()
        defer { keyReadLock.unlock() }
        cacheLock.lock()
        if let cached = keyCache[provider] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let value = Keychain.read(service: provider.keychainService, account: "api-key")
        cacheLock.lock()
        keyCache[provider] = value
        cacheLock.unlock()
        return value
    }

    /// Non-secret launch metadata. The UI can show which providers are
    /// configured without probing every protected Keychain item at startup.
    nonisolated static func hasConfiguredHint(for provider: LLMProvider) -> Bool {
        configuredHints().contains(provider)
    }

    /// Records that a provider has a saved key. The key itself never leaves
    /// the Keychain; this hint only prevents unnecessary startup prompts.
    nonisolated static func markConfiguredHint(for provider: LLMProvider) {
        cacheLock.lock()
        var hints = configuredHintsLocked()
        hints.insert(provider)
        configuredHintCache = hints
        UserDefaults.standard.set(
            hints.map(\.rawValue).sorted(), forKey: configuredHintDefaultsKey)
        cacheLock.unlock()
    }

    nonisolated static func clearConfiguredHint(for provider: LLMProvider) {
        cacheLock.lock()
        var hints = configuredHintsLocked()
        hints.remove(provider)
        configuredHintCache = hints
        UserDefaults.standard.set(
            hints.map(\.rawValue).sorted(), forKey: configuredHintDefaultsKey)
        cacheLock.unlock()
    }

    private nonisolated static func configuredHints() -> Set<LLMProvider> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return configuredHintsLocked()
    }

    private nonisolated static func configuredHintsLocked() -> Set<LLMProvider> {
        if let configuredHintCache { return configuredHintCache }
        let values = UserDefaults.standard.stringArray(forKey: configuredHintDefaultsKey) ?? []
        let hints = Set(values.compactMap(LLMProvider.init(rawValue:)))
        configuredHintCache = hints
        return hints
    }

    func key(for provider: LLMProvider) -> String? {
        Self.key(provider: provider)
    }

    func hasKey(for provider: LLMProvider) -> Bool {
        Self.hasConfiguredHint(for: provider)
    }

    var configuredProviders: Set<LLMProvider> {
        var providers = Self.configuredHints()
        // Custom servers often run keyless (Ollama/LM Studio): usable as
        // soon as a base URL is configured.
        if LLMProvider.custom.openAICompatibleBaseURL != nil {
            providers.insert(.custom)
        }
        return providers
    }

    @discardableResult
    func save(key: String, for provider: LLMProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard Keychain.write(trimmed, service: provider.keychainService, account: "api-key") else {
            return false
        }
        Self.cacheLock.lock()
        Self.keyCache[provider] = trimmed
        Self.cacheLock.unlock()
        Self.markConfiguredHint(for: provider)
        objectWillChange.send()
        return true
    }

    func deleteKey(for provider: LLMProvider) {
        Keychain.delete(service: provider.keychainService, account: "api-key")
        Self.cacheLock.lock()
        Self.keyCache[provider] = nil
        Self.cacheLock.unlock()
        Self.clearConfiguredHint(for: provider)
        objectWillChange.send()
    }
}
