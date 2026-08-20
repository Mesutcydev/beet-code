import Foundation

/// Wire protocol used by a remote model. OpenCode deliberately exposes more
/// than one provider protocol behind the same provider/model picker, so the
/// endpoint must carry this capability instead of guessing from the URL.
enum RemoteAPIProtocol: String, Codable, Sendable, Equatable {
    case openAIChatCompletions
    case openAIResponses
    case anthropicMessages
    case gemini

    var label: String {
        switch self {
        case .openAIChatCompletions: "OpenAI chat"
        case .openAIResponses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic Messages"
        case .gemini: "Google Gemini"
        }
    }

    /// OpenCode provider definitions identify their AI SDK package. These
    /// package names are part of the public config contract and are a more
    /// reliable signal than a model-name heuristic.
    static func inferred(
        providerID: String,
        model: String = "",
        package: String? = nil
    ) -> RemoteAPIProtocol {
        let package = package?.lowercased() ?? ""
        let provider = providerID.lowercased()
        let model = model.lowercased()

        if package.contains("anthropic") || provider == "anthropic" {
            return .anthropicMessages
        }
        if package.contains("google") || package.contains("gemini")
            || provider == "gemini" || provider.contains("vertex") {
            return .gemini
        }
        if package.contains("openai-compatible") {
            return .openAIChatCompletions
        }
        if package.contains("openai") {
            return .openAIResponses
        }

        // OpenCode Zen/Go use a mixed gateway: GPT/Codex models speak
        // Responses, Claude/Qwen/MiniMax models speak Messages, and the
        // remaining models use chat completions.
        if provider == "opencode" || provider == "opencode-go" {
            if model.contains("claude") || model.contains("qwen") || model.contains("minimax") {
                return .anthropicMessages
            }
            if model.contains("gpt") || model.contains("codex") {
                return .openAIResponses
            }
        }

        return .openAIChatCompletions
    }
}
