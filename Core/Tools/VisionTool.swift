import Foundation

/// Vision support:
/// - Local first: an installed SmolVLM2 sidecar (catalog role `.vision`)
///   runs in-process via `VisionEngine` — works fully offline.
/// - BYOK fallback: providers with `supportsVision` (OpenAI, Gemini,
///   OpenRouter) describe the image over their chat-completions APIs.
/// - `VisionProvider` abstracts image understanding for the composer
///   attachment flow, the `describe_image` tool, and simulator screenshots.
enum VisionProvider {

    /// Everything the engine needs to run a local vision describe.
    struct LocalResolution: Sendable {
        let model: CatalogModel
        let directory: URL
        let diskBytes: Int64
    }

    /// The installed local vision model to use, if any. Prefers the larger
    /// (higher-quality) sidecar when several are downloaded. MainActor hop:
    /// ModelStore is main-isolated.
    static func resolveLocal() async -> LocalResolution? {
        await MainActor.run {
            let store = ModelStore.shared
            return pickVisionModel(
                from: ModelCatalog.all,
                isInstalled: { store.installedModel(id: $0) != nil })
                .flatMap { model in
                    store.installedModel(id: model.id).map {
                        LocalResolution(
                            model: model,
                            directory: store.directory(for: $0),
                            diskBytes: $0.sizeBytes)
                    }
                }
        }
    }

    /// Pure picker: vision-role catalog entries, largest first, first one
    /// that is installed. Extracted for hermetic tests.
    static func pickVisionModel(
        from catalog: [CatalogModel],
        isInstalled: (String) -> Bool
    ) -> CatalogModel? {
        catalog
            .filter { $0.role == .vision }
            .sorted { $0.diskBytes > $1.diskBytes }
            .first { isInstalled($0.id) }
    }

    /// Test seam: replaces local resolution (the real one reads the
    /// main-isolated ModelStore and the host's Downloads).
    nonisolated(unsafe) static var localResolver:
        @Sendable () async -> LocalResolution? = { await resolveLocal() }

    /// Test seam: replaces the local describe (the hermetic suite never
    /// touches MLX).
    nonisolated(unsafe) static var localDescribe:
        @Sendable (LocalResolution, URL, String) async throws -> String = { resolution, url, prompt in
            try await VisionEngine.shared.describe(
                imageAt: url, prompt: prompt,
                model: resolution.model, directory: resolution.directory,
                diskBytes: resolution.diskBytes)
        }

    static var isAvailable: Bool {
        get async {
            if await localResolver() != nil { return true }
            return byokAvailable
        }
    }

    private static var byokAvailable: Bool {
        for provider in LLMProvider.allCases where provider.supportsVision {
            if APIKeyStore.key(provider: provider) != nil { return true }
        }
        return false
    }

    /// Describes an image at `fileURL`: local SmolVLM2 sidecar first,
    /// falling back to the first configured vision-capable BYOK provider.
    static func describe(imageAt fileURL: URL, prompt: String) async throws -> String {
        if let resolution = await localResolver() {
            do {
                return try await localDescribe(resolution, fileURL, prompt)
            } catch {
                Log.engine.error(
                    "Local vision describe failed, falling back to BYOK: \(String(describing: error), privacy: .public)")
            }
        }
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
                return "No vision model available. Download SmolVLM2 in the Model Manager (⇧⌘M) or add a vision-capable API key (OpenAI, Gemini, OpenRouter) in Settings."
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

/// Agent tool: describe an image inside the workspace. Uses the local
/// SmolVLM2 sidecar when one is downloaded, otherwise a vision-capable BYOK
/// provider (OpenAI, Gemini, OpenRouter).
struct DescribeImageTool: AgentTool {
    let name = "describe_image"
    let summary = "Describe an image file using the local SmolVLM2 vision model or a vision-capable BYOK provider"
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