import Foundation

/// Vision support (v0.3):
/// - `VisionProvider` abstracts image understanding.
/// - BYOK providers with `supportsVision` (OpenAI, Gemini, OpenRouter)
///   implement it over their chat-completions APIs with image parts.
/// - A local SmolVLM engine can be plugged in behind the same protocol once
///   mlx-swift-lm upstreams VLM support (tracked in mlx-swift-examples PR
///   #206); the tool interface will not change.
enum VisionProvider {

    static var isAvailable: Bool {
        for provider in LLMProvider.allCases where provider.supportsVision {
            if APIKeyStore.key(provider: provider) != nil { return true }
        }
        return false
    }

    /// Describes an image at `fileURL` using the first configured
    /// vision-capable BYOK provider.
    static func describe(imageAt fileURL: URL, prompt: String) async throws -> String {
        for provider in LLMProvider.allCases where provider.supportsVision {
            guard let apiKey = APIKeyStore.key(provider: provider) else { continue }
            let model = AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
                ?? provider.defaultModel
            do {
                return try await send(
                    provider: provider,
                    apiKey: apiKey,
                    model: model,
                    imageURL: fileURL,
                    prompt: prompt)
            } catch {
                // Try the next configured provider.
                continue
            }
        }
        throw VisionError.noProvider
    }

    enum VisionError: Error, LocalizedError {
        case noProvider
        case badImage

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "No vision-capable BYOK provider configured (OpenAI, Gemini, or OpenRouter with an API key in Settings)."
            case .badImage:
                return "The image could not be read or encoded."
            }
        }
    }

    // MARK: Request plumbing

    private static func send(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        imageURL: URL,
        prompt: String
    ) async throws -> String {
        guard let data = try? Data(contentsOf: imageURL) else { throw VisionError.badImage }
        let base64 = data.base64EncodedString()

        if provider == .gemini {
            return try await geminiRequest(
                apiKey: apiKey, model: model, base64: base64, prompt: prompt)
        }
        guard let base = provider.openAICompatibleBaseURL else { throw VisionError.noProvider }
        return try await openAICompatibleRequest(
            provider: provider, baseURL: base, apiKey: apiKey,
            model: model, base64: base64, prompt: prompt)
    }

    private static func openAICompatibleRequest(
        provider: LLMProvider,
        baseURL: URL,
        apiKey: String,
        model: String,
        base64: String,
        prompt: String
    ) async throws -> String {
        // OpenAI-style image_url part; OpenRouter accepts the same shape.
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "text", "text": prompt,
                ], [
                    "type": "image_url",
                    "image_url": ["url": "data:image/png;base64,\(base64)"],
                ]],
            ]],
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        if provider == .openRouter {
            request.setValue("Beet Code", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Beet Code", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.transport("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw RemoteLLMError.badStatus(http.statusCode, bodyText)
        }
        return try extractContent(from: data)
    }

    private static func geminiRequest(
        apiKey: String,
        model: String,
        base64: String,
        prompt: String
    ) async throws -> String {
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": prompt], ["inlineData": ["mimeType": "image/png", "data": base64]]],
            ]],
        ]
        guard let base = LLMProvider.gemini.geminiBaseURL else { throw VisionError.noProvider }
        let url = base
            .appendingPathComponent("models/\(model):generateContent")
            .appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.transport("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw RemoteLLMError.badStatus(http.statusCode, bodyText)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let parts = candidates.first?["content"] as? [String: Any] ?? nil,
              let partList = parts["parts"] as? [[String: Any]]
        else { return "(empty response)" }
        return partList.compactMap { $0["text"] as? String }.joined()
    }

    private static func extractContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteLLMError.badStatus(-1, "unparseable response")
        }
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw RemoteLLMError.badStatus(-1, message)
        }
        return "(empty response)"
    }
}

/// Agent tool: describe an image inside the workspace using a vision-capable
/// BYOK provider. This is the seam where a local SmolVLM engine will plug in
/// once mlx-swift-lm ships VLM support.
struct DescribeImageTool: AgentTool {
    let name = "describe_image"
    let summary = "Describe an image file using a vision-capable BYOK provider (OpenAI, Gemini, OpenRouter)"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "path":{"type":"string","description":"Image path inside the workspace"},
          "prompt":{"type":"string","description":"What to ask about the image (default: describe it)"}
        },"required":["path"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let path = call.string("path") else { throw ToolError.missingArgument("path") }
        let url = try context.workspace.resolve(path, access: .read).url
        let prompt = call.string("prompt") ?? "Describe this image in detail."
        let description = try await VisionProvider.describe(imageAt: url, prompt: prompt)
        return description
    }
}