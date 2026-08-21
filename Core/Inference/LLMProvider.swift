import Foundation

/// A provider-facing reasoning effort value. The raw value is what travels on
/// the wire; the labels are intentionally more human than a row of generic
/// Low / Medium / High controls so the selector can explain the trade-off.
struct ReasoningEffort: Identifiable, Sendable, Equatable, Hashable {
    let rawValue: String

    var id: String { rawValue }

    var label: String {
        switch rawValue.lowercased() {
        case "none": "Quiet"
        case "minimal": "Spark"
        case "low": "Cruise"
        case "medium": "Focus"
        case "high": "Deep"
        case "xhigh": "Orbit"
        case "max": "Overdrive"
        default:
            rawValue
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    var detail: String {
        switch rawValue.lowercased() {
        case "none": "Skip deliberate reasoning"
        case "minimal": "A quick spark before the answer"
        case "low": "Fast and lightly considered"
        case "medium": "Balanced thought and speed"
        case "high": "Longer, more deliberate thinking"
        case "xhigh": "Extended deep-work mode"
        case "max": "Use the full reasoning runway"
        default: "Provider-defined reasoning mode"
        }
    }

    var glyph: String {
        switch rawValue.lowercased() {
        case "none": "circle.slash"
        case "minimal": "sparkles"
        case "low": "wind"
        case "medium": "scope"
        case "high": "brain.head.profile"
        case "xhigh": "orbit"
        case "max": "flame.fill"
        default: "wand.and.stars"
        }
    }

    /// Used by the reactor control to make more effort feel visually denser.
    var energy: Double {
        switch rawValue.lowercased() {
        case "none": 0.12
        case "minimal": 0.22
        case "low": 0.38
        case "medium": 0.56
        case "high": 0.74
        case "xhigh": 0.9
        case "max": 1.0
        default: 0.56
        }
    }

    init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value != "default", value != "automatic" else { return nil }
        self.rawValue = value
    }

    static let standardRawValues = ["low", "medium", "high"]

    static func options(from rawValues: [String]) -> [ReasoningEffort] {
        var seen = Set<String>()
        return rawValues
            .compactMap(ReasoningEffort.init)
            .filter { seen.insert($0.rawValue).inserted }
            .sorted { lhs, rhs in
                let lhsRank = ordering.firstIndex(of: lhs.rawValue) ?? ordering.count
                let rhsRank = ordering.firstIndex(of: rhs.rawValue) ?? ordering.count
                return lhsRank == rhsRank
                    ? lhs.rawValue < rhs.rawValue
                    : lhsRank < rhsRank
            }
    }

    private static let ordering = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
}

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
    case openCodeGo
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
        case .openCode: "OpenCode Zen"
        case .openCodeGo: "OpenCode Go"
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
        case .openCodeGo: URL(string: "https://opencode.ai/zen/go/v1")
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
        case .deepSeek, .longCat, .alibaba, .alibabaTokenPlan, .openCode, .openCodeGo, .anthropic, .custom: false
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
        case .openCode: "gpt-5.6-luna"
        case .openCodeGo: "kimi-k3"
        case .anthropic: "claude-sonnet-4-5"
        case .custom: ""  // user must type the model id served by their endpoint
        }
    }

    /// Curated model ids shown before a provider's live `/models` response is
    /// available. The live response remains authoritative when it succeeds.
    var availableModels: [String] { suggestedModels }

    /// Model presets offered in the BYOK settings UI.
    /// Static fallback model list — shown before a live `/v1/models` fetch
    /// succeeds. Keep to the CURRENT generation; the live fetch (triggered
    /// automatically when a key is saved) is the source of truth.
    var suggestedModels: [String] {
        switch self {
        case .openAI: [
            "gpt-5.2", "gpt-5.2-pro", "gpt-5.1", "gpt-5", "gpt-5-mini", "gpt-5-nano",
            "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini",
            "o3", "o4-mini", "gpt-oss-120b", "gpt-oss-20b",
        ]
        case .deepSeek: ["deepseek-chat", "deepseek-reasoner"]
        case .longCat: ["LongCat-2.0", "LongCat-2.0-thinking"]
        case .alibaba: [
            "qwen-plus", "qwen-max", "qwen-turbo", "qwen3-coder-plus", "qwen3-coder-flash",
            "qwen3-max", "qwen3.5-plus",
        ]
        case .alibabaTokenPlan: [
            "qwen3.8-max", "qwen3.7-max", "qwen3.7-plus", "qwen3.6-flash",
            "qwen3-coder-plus", "deepseek-v4-pro", "deepseek-v4-flash-0731", "glm-5.2",
        ]
        case .gemini: [
            "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash",
            "gemini-3.5-flash-lite", "gemini-3.1-pro-preview", "gemini-2.5-pro",
            "gemini-2.5-flash", "gemini-2.5-flash-lite",
        ]
        case .openRouter: [
            "openrouter/auto", "openai/gpt-5.2", "openai/gpt-5",
            "anthropic/claude-opus-5", "anthropic/claude-sonnet-4.6",
            "google/gemini-3.7-flash", "deepseek/deepseek-reasoner",
            "qwen/qwen3.8-max", "moonshotai/kimi-k3", "meta-llama/llama-4-maverick",
        ]
        case .openCode: [
            "gpt-5.6-luna", "claude-opus-5", "claude-opus-4-6", "gpt-5.6-sol", "grok-4.5",
        ]
        case .openCodeGo: [
            "kimi-k3", "grok-4.5", "glm-5.2", "minimax-m3", "qwen3.8-max",
        ]
        case .anthropic: [
            "claude-opus-5", "claude-opus-4-8", "claude-opus-4-6",
            "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-haiku-4-5",
        ]
        case .custom: []
        }
    }

    /// Keychain service name for this provider's API key.
    var keychainService: String { "com.beetcode.provider.\(rawValue)" }

    /// Custom/local servers often run without auth (Ollama, LM Studio).
    var keyOptional: Bool { self == .custom }

    /// Credential guidance shown next to the provider's key field. Keep this
    /// provider-specific so a key from another gateway is not mistaken for a
    /// broken Gemini request.
    var credentialHint: String? {
        switch self {
        case .gemini:
            "Use a Google AI Studio Gemini API key here. A key issued by another gateway or service will be rejected by Google's endpoint."
        case .openCode, .openCodeGo:
            "Use the API key issued for this OpenCode service. Zen and Go keys are separate from keys issued by the underlying model provider."
        default:
            nil
        }
    }

    /// Maps an OpenCode provider id to a built-in Beet Code provider when the
    /// same wire protocol and credential semantics are already implemented.
    /// Unknown ids stay dynamic and are represented by `.custom` plus the
    /// imported provider definition.
    static func fromOpenCodeIdentifier(_ identifier: String) -> LLMProvider? {
        switch identifier.lowercased() {
        case "openai": .openAI
        case "deepseek": .deepSeek
        case "longcat": .longCat
        case "alibaba", "dashscope", "qwen": .alibaba
        case "gemini", "google": .gemini
        case "openrouter": .openRouter
        case "opencode", "open-code", "open-code-zen": .openCode
        case "opencode-go", "opencode_go", "opencodego": .openCodeGo
        case "anthropic", "claude": .anthropic
        case "ollama", "lmstudio", "lm-studio", "vllm", "llamacpp": .custom
        default: nil
        }
    }

    var remoteAPIProtocol: RemoteAPIProtocol {
        switch self {
        case .gemini: .gemini
        case .anthropic: .anthropicMessages
        case .openCode, .openCodeGo:
            .openAIChatCompletions
        default: .openAIChatCompletions
        }
    }

    func remoteAPIProtocol(for model: String) -> RemoteAPIProtocol {
        switch self {
        case .gemini: .gemini
        case .anthropic: .anthropicMessages
        case .openCode, .openCodeGo:
            RemoteAPIProtocol.inferred(providerID: rawValue == "openCodeGo" ? "opencode-go" : "opencode", model: model)
        default: remoteAPIProtocol
        }
    }
}

/// Static capability hints for model ids whose `/models` response only
/// contains an id. These are deliberately conservative: the live model
/// profile can replace them, and an unknown custom model never gets a
/// reasoning control unless its metadata or an explicit capability override
/// says it supports reasoning.
enum RemoteModelCatalog {
    static func reasoningEfforts(
        provider: LLMProvider,
        providerKey: String? = nil,
        model: String
    ) -> [ReasoningEffort] {
        let key = (providerKey ?? provider.rawValue).lowercased()
        let modelID = model.lowercased()

        if key == "tabitoken" {
            return modelID.contains("claude") ? claudeEfforts : modelLooksReasoning(modelID) ? standardEfforts : []
        }

        switch provider {
        case .openAI:
            if modelID.contains("gpt-5-pro") { return options(["high"]) }
            if modelID.contains("gpt-5.1") { return options(["none", "low", "medium", "high"]) }
            if modelID.contains("gpt-5") || modelID.hasPrefix("o1") || modelID.hasPrefix("o3") || modelID.hasPrefix("o4") {
                return standardEfforts
            }
            return []
        case .deepSeek:
            return modelID.contains("reasoner") ? standardEfforts : []
        case .longCat:
            return modelID.contains("thinking") ? standardEfforts : []
        case .alibaba, .alibabaTokenPlan:
            return modelLooksReasoning(modelID) ? standardEfforts : []
        case .gemini:
            return modelID.contains("gemini-2.5") || modelID.contains("gemini-3")
                ? geminiEfforts
                : []
        case .anthropic:
            if modelID.contains("opus-5") { return claudeEfforts }
            return modelID.contains("claude") ? standardEfforts : []
        case .openRouter, .openCode, .openCodeGo, .custom:
            if modelID.contains("claude-opus-5") { return claudeEfforts }
            return modelLooksReasoning(modelID) ? standardEfforts : []
        }
    }

    static func defaultReasoningEffort(
        provider: LLMProvider,
        providerKey: String? = nil,
        model: String
    ) -> String? {
        let efforts = reasoningEfforts(provider: provider, providerKey: providerKey, model: model)
        if efforts.contains(where: { $0.rawValue == "high" }) {
            let key = (providerKey ?? provider.rawValue).lowercased()
            return key == "tabitoken" || model.lowercased().contains("claude-opus-5") ? "high" : "medium"
        }
        return efforts.first?.rawValue
    }

    private static let standardEfforts = options(["low", "medium", "high"])
    private static let geminiEfforts = options(["minimal", "low", "medium", "high"])
    private static let claudeEfforts = options(["low", "medium", "high", "xhigh", "max"])

    private static func options(_ values: [String]) -> [ReasoningEffort] {
        ReasoningEffort.options(from: values)
    }

    private static func modelLooksReasoning(_ model: String) -> Bool {
        model.contains("reason") || model.contains("think") || model.contains("deepseek-r1")
            || model.contains("deepseek-v4") || model.contains("qwen3") || model.contains("magistral")
            || model.contains("gpt-5") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4")
            || model.contains("gemini-2.5") || model.contains("gemini-3")
    }
}

/// A configured remote endpoint: provider + model choice.
struct RemoteEndpoint: Codable, Sendable, Equatable {
    var provider: LLMProvider
    var model: String
    /// Dynamic provider id imported from OpenCode. Nil for the built-in
    /// provider cards above.
    var providerID: String?
    var displayName: String?
    var baseURL: URL?
    var apiProtocol: RemoteAPIProtocol?
    var headers: [String: String]
    /// Runtime-only credential resolved from an OpenCode env/file reference.
    /// It is intentionally excluded from Codable so endpoints can never put a
    /// secret into a persisted session or preferences file.
    var apiKey: String?

    private enum CodingKeys: String, CodingKey {
        case provider, model, providerID, displayName, baseURL, apiProtocol, headers
    }

    init(
        provider: LLMProvider,
        model: String,
        providerID: String? = nil,
        displayName: String? = nil,
        baseURL: URL? = nil,
        apiProtocol: RemoteAPIProtocol? = nil,
        headers: [String: String] = [:],
        apiKey: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.providerID = providerID
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiProtocol = apiProtocol
        self.headers = headers
        self.apiKey = apiKey
    }

    var effectiveProviderKey: String { providerID ?? provider.rawValue }
    var effectiveDisplayName: String { displayName ?? provider.displayName }
    var effectiveBaseURL: URL? {
        baseURL
            ?? provider.openAICompatibleBaseURL
            ?? provider.geminiBaseURL
            ?? provider.anthropicBaseURL
    }
    var effectiveProtocol: RemoteAPIProtocol {
        apiProtocol ?? provider.remoteAPIProtocol(for: model)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(LLMProvider.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        baseURL = try container.decodeIfPresent(URL.self, forKey: .baseURL)
        apiProtocol = try container.decodeIfPresent(RemoteAPIProtocol.self, forKey: .apiProtocol)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        apiKey = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(providerID, forKey: .providerID)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(apiProtocol, forKey: .apiProtocol)
        try container.encode(headers, forKey: .headers)
    }
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
    var supportedReasoningEfforts: [String]
    var defaultReasoningEffort: String?
    /// Dynamic OpenCode provider identity. Built-in profiles leave this nil.
    var providerKey: String?
    var providerDisplayName: String?
    var apiProtocol: RemoteAPIProtocol?
    var baseURL: String?
    var headers: [String: String]
    /// Runtime-only credential from an imported config; excluded from JSON.
    var apiKey: String?

    private enum CodingKeys: String, CodingKey {
        case provider, model, displayName, contextWindow, maxOutputTokens,
             supportsVision, supportsTools, supportsReasoning, supportsTemperature,
             supportedReasoningEfforts, defaultReasoningEffort,
             providerKey, providerDisplayName, apiProtocol, baseURL, headers
    }

    var id: String { "\(providerKey ?? provider.rawValue):\(model)" }
    var displayProviderName: String { providerDisplayName ?? provider.displayName }

    var effectiveReasoningEfforts: [ReasoningEffort] {
        // An explicit Off override wins over curated hints and gateway
        // metadata, so the control and the wire payload stay in sync.
        guard supportsReasoning != false else { return [] }
        let declared = ReasoningEffort.options(from: supportedReasoningEfforts)
        if !declared.isEmpty { return declared }
        let curated = RemoteModelCatalog.reasoningEfforts(
            provider: provider, providerKey: providerKey, model: model)
        if !curated.isEmpty { return curated }
        return supportsReasoning == true
            ? ReasoningEffort.options(from: ReasoningEffort.standardRawValues)
            : []
    }

    var effectiveDefaultReasoningEffort: String? {
        if let defaultReasoningEffort,
           effectiveReasoningEfforts.contains(where: { $0.rawValue == defaultReasoningEffort.lowercased() }) {
            return defaultReasoningEffort.lowercased()
        }
        return RemoteModelCatalog.defaultReasoningEffort(
            provider: provider, providerKey: providerKey, model: model)
    }

    func selectedReasoningEffort(using override: RemoteModelOverride?) -> String? {
        guard let selected = override?.reasoningEffort?.lowercased(),
              effectiveReasoningEfforts.contains(where: { $0.rawValue == selected })
        else { return nil }
        return selected
    }

    init(
        provider: LLMProvider,
        model: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsVision: Bool? = nil,
        supportsTools: Bool? = nil,
        supportsReasoning: Bool? = nil,
        supportsTemperature: Bool? = nil,
        supportedReasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil,
        providerKey: String? = nil,
        providerDisplayName: String? = nil,
        apiProtocol: RemoteAPIProtocol? = nil,
        baseURL: String? = nil,
        headers: [String: String] = [:],
        apiKey: String? = nil
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
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.providerKey = providerKey
        self.providerDisplayName = providerDisplayName
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.headers = headers
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(LLMProvider.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        supportsVision = try container.decodeIfPresent(Bool.self, forKey: .supportsVision)
        supportsTools = try container.decodeIfPresent(Bool.self, forKey: .supportsTools)
        supportsReasoning = try container.decodeIfPresent(Bool.self, forKey: .supportsReasoning)
        supportsTemperature = try container.decodeIfPresent(Bool.self, forKey: .supportsTemperature)
        supportedReasoningEfforts = try container.decodeIfPresent([String].self, forKey: .supportedReasoningEfforts) ?? []
        defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        providerKey = try container.decodeIfPresent(String.self, forKey: .providerKey)
        providerDisplayName = try container.decodeIfPresent(String.self, forKey: .providerDisplayName)
        apiProtocol = try container.decodeIfPresent(RemoteAPIProtocol.self, forKey: .apiProtocol)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        apiKey = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encodeIfPresent(supportsVision, forKey: .supportsVision)
        try container.encodeIfPresent(supportsTools, forKey: .supportsTools)
        try container.encodeIfPresent(supportsReasoning, forKey: .supportsReasoning)
        try container.encodeIfPresent(supportsTemperature, forKey: .supportsTemperature)
        try container.encode(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try container.encodeIfPresent(defaultReasoningEffort, forKey: .defaultReasoningEffort)
        try container.encodeIfPresent(providerKey, forKey: .providerKey)
        try container.encodeIfPresent(providerDisplayName, forKey: .providerDisplayName)
        try container.encodeIfPresent(apiProtocol, forKey: .apiProtocol)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encode(headers, forKey: .headers)
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

    func endpoint() -> RemoteEndpoint {
        RemoteEndpoint(
            provider: provider,
            model: model,
            providerID: providerKey,
            displayName: providerDisplayName,
            baseURL: baseURL.flatMap(URL.init(string:)),
            apiProtocol: apiProtocol,
            headers: headers,
            apiKey: apiKey)
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
    var reasoningEffort: String?

    init(
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsVision: Bool? = nil,
        supportsTools: Bool? = nil,
        supportsReasoning: Bool? = nil,
        supportsTemperature: Bool? = nil,
        reasoningEffort: String? = nil
    ) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.supportsTemperature = supportsTemperature
        self.reasoningEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isEmpty: Bool {
        contextWindow == nil && maxOutputTokens == nil && supportsVision == nil
            && supportsTools == nil && supportsReasoning == nil
            && supportsTemperature == nil && reasoningEffort == nil
    }
}

/// Keychain-backed storage for provider API keys. Keys are credentials —
/// they never touch UserDefaults or the session files.
enum CredentialNormalizer {

    /// Accept the common copy/paste forms users get from curl examples and
    /// provider dashboards, while leaving the credential value itself
    /// untouched. This is deliberately local cleanup — it never guesses a
    /// provider or transforms the key beyond an explicit wrapper/prefix.
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let prefixes = ["Bearer ", "api-key:", "api_key:", "api-key=", "api_key=", "key:", "key="]
        for prefix in prefixes where value.count >= prefix.count {
            let prefixEnd = value.index(value.startIndex, offsetBy: prefix.count)
            guard value[..<prefixEnd].caseInsensitiveCompare(prefix) == .orderedSame else {
                continue
            }
            value = String(value[prefixEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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
    nonisolated(unsafe) private static var dynamicKeyCache: [String: String?] = [:]
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

    /// Keychain access for providers imported from OpenCode. The provider id
    /// is hashed for the service name so arbitrary config ids cannot create
    /// invalid Keychain service strings or leak configuration names into the
    /// Keychain metadata.
    nonisolated static func key(providerID: String) -> String? {
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        keyReadLock.lock()
        defer { keyReadLock.unlock() }
        cacheLock.lock()
        if let cached = dynamicKeyCache[id] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let value = Keychain.read(service: keychainService(providerID: id), account: "api-key")
        cacheLock.lock()
        dynamicKeyCache[id] = value
        cacheLock.unlock()
        return value
    }

    nonisolated static func keychainService(providerID: String) -> String {
        "com.beetcode.provider.dynamic.\(ContentDigest.sha256Hex(providerID))"
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

    func key(forProviderID providerID: String) -> String? {
        Self.key(providerID: providerID)
    }

    func hasKey(for provider: LLMProvider) -> Bool {
        Self.hasConfiguredHint(for: provider)
    }

    func hasKey(forProviderID providerID: String) -> Bool {
        Self.key(providerID: providerID) != nil
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
        let trimmed = CredentialNormalizer.normalize(key)
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

    @discardableResult
    func save(key: String, forProviderID providerID: String) -> Bool {
        let trimmed = CredentialNormalizer.normalize(key)
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !id.isEmpty else { return false }
        guard Keychain.write(
            trimmed,
            service: Self.keychainService(providerID: id),
            account: "api-key")
        else { return false }
        Self.cacheLock.lock()
        Self.dynamicKeyCache[id] = trimmed
        Self.cacheLock.unlock()
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

    func deleteKey(forProviderID providerID: String) {
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        Keychain.delete(service: Self.keychainService(providerID: id), account: "api-key")
        Self.cacheLock.lock()
        Self.dynamicKeyCache[id] = nil
        Self.cacheLock.unlock()
        objectWillChange.send()
    }
}
