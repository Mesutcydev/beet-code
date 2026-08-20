import Foundation

/// Named presets for popular gateways that expose an OpenAI-compatible API.
/// They intentionally stay separate from `LLMProvider`: a preset is a
/// discoverable connection profile, while the engine only needs the generic
/// `.custom` transport plus a stable dynamic provider id.
struct KnownRemoteProvider: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let baseURL: URL
    let defaultModel: String
    let suggestedModels: [String]
    let apiProtocol: RemoteAPIProtocol

    func endpoint(model: String? = nil) -> RemoteEndpoint {
        let selectedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = selectedModel.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        return RemoteEndpoint(
            provider: .custom,
            model: modelID,
            providerID: id,
            displayName: displayName,
            baseURL: baseURL,
            apiProtocol: apiProtocol)
    }

    static let all: [KnownRemoteProvider] = [
        .init(
            id: "mistral",
            displayName: "Mistral AI",
            baseURL: URL(string: "https://api.mistral.ai/v1")!,
            defaultModel: "mistral-large-latest",
            suggestedModels: ["mistral-large-latest", "codestral-latest", "ministral-8b-latest"],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "groq",
            displayName: "Groq",
            baseURL: URL(string: "https://api.groq.com/openai/v1")!,
            defaultModel: "llama-3.3-70b-versatile",
            suggestedModels: ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "moonshotai/kimi-k2-instruct"],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "xai",
            displayName: "xAI",
            baseURL: URL(string: "https://api.x.ai/v1")!,
            defaultModel: "grok-4",
            suggestedModels: ["grok-4", "grok-3", "grok-3-mini"],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "together",
            displayName: "Together AI",
            baseURL: URL(string: "https://api.together.xyz/v1")!,
            defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            suggestedModels: [
                "meta-llama/Llama-3.3-70B-Instruct-Turbo",
                "Qwen/Qwen2.5-Coder-32B-Instruct",
            ],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "fireworks",
            displayName: "Fireworks AI",
            baseURL: URL(string: "https://api.fireworks.ai/inference/v1")!,
            defaultModel: "accounts/fireworks/models/llama-v3p1-70b-instruct",
            suggestedModels: [
                "accounts/fireworks/models/llama-v3p1-70b-instruct",
                "accounts/fireworks/models/qwen2p5-coder-32b-instruct",
            ],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "cerebras",
            displayName: "Cerebras",
            baseURL: URL(string: "https://api.cerebras.ai/v1")!,
            defaultModel: "llama-3.3-70b",
            suggestedModels: ["llama-3.3-70b", "qwen-3-32b"],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "perplexity",
            displayName: "Perplexity",
            baseURL: URL(string: "https://api.perplexity.ai")!,
            defaultModel: "sonar-pro",
            suggestedModels: ["sonar-pro", "sonar", "sonar-reasoning-pro"],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "cohere",
            displayName: "Cohere",
            baseURL: URL(string: "https://api.cohere.com/compatibility/v1")!,
            defaultModel: "command-a-03-2025",
            suggestedModels: ["command-a-03-2025", "command-r-plus"],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "huggingface",
            displayName: "Hugging Face",
            baseURL: URL(string: "https://router.huggingface.co/v1")!,
            defaultModel: "Qwen/Qwen2.5-Coder-32B-Instruct",
            suggestedModels: [
                "Qwen/Qwen2.5-Coder-32B-Instruct",
                "meta-llama/Llama-3.3-70B-Instruct",
            ],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "nvidia",
            displayName: "NVIDIA NIM",
            baseURL: URL(string: "https://integrate.api.nvidia.com/v1")!,
            defaultModel: "meta/llama-3.1-70b-instruct",
            suggestedModels: ["meta/llama-3.1-70b-instruct", "qwen/qwen2.5-coder-32b-instruct"],
            apiProtocol: .openAIChatCompletions),
        .init(
            id: "deepinfra",
            displayName: "DeepInfra",
            baseURL: URL(string: "https://api.deepinfra.com/v1/openai")!,
            defaultModel: "meta-llama/Meta-Llama-3.1-70B-Instruct",
            suggestedModels: [
                "meta-llama/Meta-Llama-3.1-70B-Instruct",
                "Qwen/Qwen2.5-Coder-32B-Instruct",
            ],
            apiProtocol: .openAIChatCompletions),
    ]

    static func find(_ id: String) -> KnownRemoteProvider? {
        all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
}
