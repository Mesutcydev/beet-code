import Foundation

/// Per-chat token totals. Prompt+completion come from the provider usage
/// chunk when the engine is remote; local engines only know completions
/// (chunk count). Cost is a rough published-rate estimate — never billed.
struct SessionUsage: Sendable, Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var turns: Int = 0

    var totalTokens: Int { promptTokens + completionTokens }

    mutating func add(prompt: Int, completion: Int) {
        guard prompt > 0 || completion > 0 else { return }
        promptTokens += max(0, prompt)
        completionTokens += max(0, completion)
        turns += 1
    }

    /// Very rough USD using public list prices. nil when we have no rate
    /// (local models, custom endpoints).
    func estimatedUSD(provider: LLMProvider?) -> Double? {
        guard let provider, let rate = Self.ratePerMillion(provider) else { return nil }
        let usd = (Double(promptTokens) * rate.prompt + Double(completionTokens) * rate.completion) / 1_000_000
        return usd
    }

    func compactLabel(provider: LLMProvider?) -> String {
        guard totalTokens > 0 else { return "" }
        var parts = ["\(Self.short(totalTokens)) tok"]
        if let usd = estimatedUSD(provider: provider), usd > 0 {
            if usd < 0.01 {
                parts.append(String(format: "$%.3f", usd))
            } else {
                parts.append(String(format: "$%.2f", usd))
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func short(_ n: Int) -> String {
        if n >= 10_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private struct Rate { var prompt: Double; var completion: Double }

    /// Per-million-token list prices. Intentionally coarse — status-bar
    /// telemetry, not an invoice.
    private static func ratePerMillion(_ provider: LLMProvider) -> Rate? {
        switch provider {
        case .openAI: return Rate(prompt: 0.15, completion: 0.60)       // gpt-4o-mini ballpark
        case .anthropic: return Rate(prompt: 3.00, completion: 15.00)   // sonnet ballpark
        case .deepSeek: return Rate(prompt: 0.28, completion: 0.42)
        case .gemini: return Rate(prompt: 0.10, completion: 0.40)
        case .openRouter: return Rate(prompt: 0.50, completion: 1.50)
        case .alibaba, .alibabaTokenPlan: return Rate(prompt: 0.40, completion: 1.20)
        case .longCat, .openCode, .openCodeGo, .custom: return nil
        }
    }
}
