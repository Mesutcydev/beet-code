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
        case .longCat: URL(string: "https://api.longcat.ai/v1")
        case .alibaba: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        case .alibabaTokenPlan: URL(string: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1")
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")
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
        return URL(string: raw)
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
        case .deepSeek, .longCat, .alibaba, .alibabaTokenPlan, .anthropic, .custom: false
        }
    }

    /// Sensible default model IDs for each provider.
    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .deepSeek: "deepseek-chat"
        case .longCat: "longcat-default"
        case .alibaba: "qwen-plus"
        case .alibabaTokenPlan: "qwen3.8-max"
        case .gemini: "gemini-2.0-flash"
        case .openRouter: "openrouter/auto"
        case .anthropic: "claude-sonnet-4-5"
        case .custom: ""  // user must type the model id served by their endpoint
        }
    }

    /// Model presets offered in the BYOK settings UI.
    var suggestedModels: [String] {
        switch self {
        case .openAI: ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini"]
        case .deepSeek: ["deepseek-chat", "deepseek-reasoner"]
        case .longCat: ["longcat-default", "longcat-ultra"]
        case .alibaba: ["qwen-plus", "qwen-max", "qwen-turbo"]
        case .alibabaTokenPlan: ["qwen3.8-max", "qwen3.7-max", "qwen3.7-plus", "qwen3.6-flash", "deepseek-v4-pro", "deepseek-v4-flash-0731", "glm-5.2"]
        case .gemini: ["gemini-2.0-flash", "gemini-2.5-flash", "gemini-2.5-pro"]
        case .openRouter: ["openrouter/auto", "anthropic/claude-3.5-sonnet", "google/gemini-2.0-flash-001"]
        case .anthropic: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-3-5-haiku-latest"]
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

/// Keychain-backed storage for provider API keys. Keys are credentials —
/// they never touch UserDefaults or the session files.
@MainActor
final class APIKeyStore: ObservableObject {

    static let shared = APIKeyStore()

    // Keys are cached in memory after the first Keychain read: at launch the
    // UI may probe every provider, and each raw SecItem access can trigger a
    // keychain password prompt on ad-hoc-signed builds.
    nonisolated private static let cacheLock = NSLock()
    // All access happens under cacheLock, which is what makes this safe.
    nonisolated(unsafe) private static var keyCache: [LLMProvider: String?] = [:]

    init() {
        // Deliberately no Keychain access here — providers are probed
        // lazily through key(for:) and cached.
    }

    /// Thread-safe key read for background engines; caches after first read.
    nonisolated static func key(provider: LLMProvider) -> String? {
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

    func key(for provider: LLMProvider) -> String? {
        Self.key(provider: provider)
    }

    var configuredProviders: Set<LLMProvider> {
        Set(LLMProvider.allCases.filter { provider in
            if key(for: provider) != nil { return true }
            // Custom servers often run keyless (Ollama/LM Studio): usable as
            // soon as a base URL is configured.
            if provider.keyOptional, provider.openAICompatibleBaseURL != nil { return true }
            return false
        })
    }

    func save(key: String, for provider: LLMProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.write(trimmed, service: provider.keychainService, account: "api-key")
        Self.cacheLock.lock()
        Self.keyCache[provider] = trimmed
        Self.cacheLock.unlock()
        objectWillChange.send()
    }

    func deleteKey(for provider: LLMProvider) {
        Keychain.delete(service: provider.keychainService, account: "api-key")
        Self.cacheLock.lock()
        Self.keyCache[provider] = nil
        Self.cacheLock.unlock()
        objectWillChange.send()
    }
}