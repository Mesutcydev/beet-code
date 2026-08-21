import Darwin
import Foundation

/// A model entry the app knows how to download and run. The bundled list is
/// curated for Apple Silicon RAM tiers; users can add arbitrary HF repos,
/// which land in the user catalog file with defaults filled in.
struct CatalogModel: Codable, Identifiable, Sendable, Hashable {
    enum Format: String, Codable, Sendable {
        case mlx
        case gguf
    }

    /// What the model is FOR. Chat models are loadable as the agent's engine;
    /// vision models are sidecars the app uses automatically to describe
    /// image attachments (never loadable as the chat engine).
    enum Role: String, Codable, Sendable {
        case chat
        case vision
    }

    var id: String
    var repo: String
    var displayName: String
    var family: String
    var parameters: String
    var quantization: String
    var diskBytes: Int64
    var contextWindow: Int
    var minRAMGB: Int
    var recommendedRAMGB: Int
    var notes: String
    /// Weights format — decides which engine runs it. MLX safetensors run
    /// in-process; GGUF runs through llama.cpp's `llama-server`.
    var format: Format = .mlx
    var role: Role = .chat

    /// Tolerant decoding: catalog files written by older builds lack
    /// `format`/`role` — fill defaults instead of dropping the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repo = try c.decode(String.self, forKey: .repo)
        displayName = try c.decode(String.self, forKey: .displayName)
        family = try c.decode(String.self, forKey: .family)
        parameters = try c.decode(String.self, forKey: .parameters)
        quantization = try c.decode(String.self, forKey: .quantization)
        diskBytes = try c.decode(Int64.self, forKey: .diskBytes)
        contextWindow = try c.decode(Int.self, forKey: .contextWindow)
        minRAMGB = try c.decode(Int.self, forKey: .minRAMGB)
        recommendedRAMGB = try c.decode(Int.self, forKey: .recommendedRAMGB)
        notes = try c.decode(String.self, forKey: .notes)
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? .mlx
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .chat
    }

    init(
        id: String, repo: String, displayName: String, family: String,
        parameters: String, quantization: String, diskBytes: Int64,
        contextWindow: Int, minRAMGB: Int, recommendedRAMGB: Int,
        notes: String, format: Format = .mlx, role: Role = .chat
    ) {
        self.id = id
        self.repo = repo
        self.displayName = displayName
        self.family = family
        self.parameters = parameters
        self.quantization = quantization
        self.diskBytes = diskBytes
        self.contextWindow = contextWindow
        self.minRAMGB = minRAMGB
        self.recommendedRAMGB = recommendedRAMGB
        self.notes = notes
        self.format = format
        self.role = role
    }

    var subtitle: String {
        "\(parameters) · \(quantization) · ~\(ByteFormatter.bytes(diskBytes))"
    }
}

/// Reads the metadata that distinguishes an ordinary MLX language model from
/// a multimodal checkpoint. Qwen3.5 keeps its language-model configuration
/// under `text_config`; using only the root-level fields makes that checkpoint
/// look like a small, generic model and sends it through the wrong factory.
enum MLXModelInspector {
    /// Model configuration is metadata, not a weight file. Refuse special
    /// files (for example a FIFO) and implausibly large inputs so catalog
    /// repair can never block the app launch or page an arbitrary file into
    /// memory.
    static let maximumConfigBytes: UInt64 = 8 * 1_024 * 1_024

    struct Metadata: Equatable, Sendable {
        let family: String
        let parameters: String
        let quantization: String
        let contextWindow: Int
        let isVisionLanguage: Bool
    }

    static func read(from directory: URL) -> Metadata? {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = readConfigData(at: configURL) else { return nil }
        return metadata(from: data, directory: directory)
    }

    /// Foundation's file-attribute lookup asks for extended attributes and
    /// can stall on unavailable volumes. A plain POSIX open/fstat is both
    /// narrower and guarantees that pipes are opened non-blocking.
    private static func readConfigData(at url: URL) -> Data? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              UInt64(status.st_size) <= maximumConfigBytes
        else { return nil }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try? handle.readToEnd()
    }

    static func metadata(from data: Data, directory: URL) -> Metadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return metadata(from: json, directory: directory)
    }

    static func isVisionLanguageModel(at directory: URL) -> Bool {
        read(from: directory)?.isVisionLanguage ?? false
    }

    /// Folders named only for their quantization (for example `2-bit`) are
    /// common when several exports live under one model directory. Include
    /// the parent model name so imports remain identifiable and collision-free.
    static func suggestedID(for directory: URL) -> String {
        let leaf = directory.lastPathComponent
        guard isQuantizationFolder(leaf) else { return leaf }

        let parent = directory.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "." else { return leaf }
        return "\(parent)-\(leaf)"
    }

    /// Uses the parent model folder as the human-facing name when the
    /// selected folder is only a quantization label such as `2-bit`.
    static func displayName(for directory: URL, metadata: Metadata) -> String {
        let leaf = directory.lastPathComponent
        let candidate = isQuantizationFolder(leaf)
            ? directory.deletingLastPathComponent().lastPathComponent
            : leaf
        guard !candidate.isEmpty, candidate != ".", candidate != "Models" else {
            return [metadata.family, metadata.parameters]
                .filter { $0 != "—" }
                .joined(separator: " ")
        }
        return candidate
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func metadata(from json: [String: Any], directory: URL) -> Metadata {
        let modelType = json["model_type"] as? String ?? "custom"
        let textConfig = json["text_config"] as? [String: Any]
        let hasVisionConfig = json["vision_config"] is [String: Any]
        let architectures = (json["architectures"] as? [String] ?? [])
            .map { $0.lowercased() }
        let isConditionalGeneration = architectures.contains { $0.contains("conditionalgeneration") }
        let isLanguageModelOnly = json["language_model_only"] as? Bool
        let isVisionLanguage = (textConfig != nil && hasVisionConfig)
            || isLanguageModelOnly == false
            || isConditionalGeneration

        let configForText = textConfig ?? json
        let contextWindow = integer(configForText["max_position_embeddings"])
            ?? integer(json["max_position_embeddings"])
            ?? 32_768

        let quantizationConfig = json["quantization_config"] as? [String: Any]
        let bits = integer(quantizationConfig?["bits"])
            ?? integer((json["quantization"] as? [String: Any])?["bits"])
        let quantization = bits.map { "\($0)-bit" }
            ?? quantizationFromPath(directory)
            ?? "—"

        return Metadata(
            family: prettyFamily(modelType),
            parameters: parameterLabel(from: directory) ?? "—",
            quantization: quantization,
            contextWindow: contextWindow,
            isVisionLanguage: isVisionLanguage)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func prettyFamily(_ raw: String) -> String {
        var label = ""
        for (index, part) in raw.split(separator: "_").enumerated() {
            let text = String(part)
            if index > 0 {
                label += text.allSatisfy({ $0.isNumber }) ? "." : " "
            }
            label += text.prefix(1).uppercased() + text.dropFirst()
        }
        return label.isEmpty ? "Custom" : label
    }

    private static func parameterLabel(from directory: URL) -> String? {
        let names = [
            directory.lastPathComponent,
            directory.deletingLastPathComponent().lastPathComponent,
        ]
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*b(?=[^a-zA-Z0-9]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        for name in names {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, range: range),
                  let valueRange = Range(match.range(at: 1), in: name) else { continue }
            return "\(name[valueRange])B"
        }
        return nil
    }

    private static func quantizationFromPath(_ directory: URL) -> String? {
        let names = [directory.lastPathComponent, directory.deletingLastPathComponent().lastPathComponent]
        let pattern = #"(?i)^(\d+)[-_]?bits?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        for name in names {
            guard let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let valueRange = Range(match.range(at: 1), in: name) else { continue }
            return "\(name[valueRange])-bit"
        }
        return nil
    }

    private static func isQuantizationFolder(_ name: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)^\d+[-_]?bits?$"#) else {
            return false
        }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range)?.range == range
    }
}

enum ModelCatalog {

    /// Files fetched when downloading a repo snapshot. Covers both MLX
    /// (safetensors + tokenizer artifacts) and GGUF (single .gguf file) repos.
    static let downloadGlobs = [
        "*.safetensors", "*.json", "tokenizer*", "*.txt", "*.jinja", "*.gguf",
    ]

    static let bundled: [CatalogModel] = [
        CatalogModel(
            id: "qwen3-1.7b-4bit",
            repo: "mlx-community/Qwen3-1.7B-4bit",
            displayName: "Qwen3 1.7B",
            family: "Qwen3",
            parameters: "1.7B",
            quantization: "4-bit",
            diskBytes: 1_100_000_000,
            contextWindow: 32_768,
            minRAMGB: 6,
            recommendedRAMGB: 8,
            notes: "Fastest starter model for 8 GB Macs. Good for trying the agent; limited coding depth."),
        CatalogModel(
            id: "qwen3-4b-4bit",
            repo: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen3 4B",
            family: "Qwen3",
            parameters: "4B",
            quantization: "4-bit",
            diskBytes: 2_400_000_000,
            contextWindow: 32_768,
            minRAMGB: 8,
            recommendedRAMGB: 12,
            notes: "Best balance for 8–12 GB Macs. Solid tool use with the prompt protocol."),
        CatalogModel(
            id: "qwen2.5-coder-7b-4bit",
            repo: "mlx-community/Qwen2.5-Coder-7B-4bit",
            displayName: "Qwen2.5 Coder 7B",
            family: "Qwen2.5 Coder",
            parameters: "7B",
            quantization: "4-bit",
            diskBytes: 4_100_000_000,
            contextWindow: 32_768,
            minRAMGB: 12,
            recommendedRAMGB: 16,
            notes: "Code-specialized. Strong edit accuracy for its size."),
        CatalogModel(
            id: "qwen3-8b-4bit",
            repo: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B",
            family: "Qwen3",
            parameters: "8B",
            quantization: "4-bit",
            diskBytes: 4_900_000_000,
            contextWindow: 32_768,
            minRAMGB: 12,
            recommendedRAMGB: 16,
            notes: "Reasoning-capable generalist. Runs with thinking disabled for snappy tool turns."),
        CatalogModel(
            id: "qwen3-coder-14b-4bit",
            repo: "mlx-community/Qwen3-Coder-14B-4bit",
            displayName: "Qwen3 Coder 14B",
            family: "Qwen3 Coder",
            parameters: "14B",
            quantization: "4-bit",
            diskBytes: 9_000_000_000,
            contextWindow: 65_536,
            minRAMGB: 18,
            recommendedRAMGB: 24,
            notes: "Serious coding model for 24 GB Macs."),
        CatalogModel(
            id: "qwen3-coder-30b-a3b-4bit",
            repo: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            displayName: "Qwen3 Coder 30B A3B",
            family: "Qwen3 Coder",
            parameters: "30B (3B active)",
            quantization: "4-bit",
            diskBytes: 17_000_000_000,
            contextWindow: 65_536,
            minRAMGB: 24,
            recommendedRAMGB: 32,
            notes: "Mixture-of-experts: 30B quality at near-8B speed. The pick for 24 GB+."),

        // GGUF (llama.cpp) — the widest quantization/architecture coverage.
        CatalogModel(
            id: "qwen2.5-coder-7b-gguf-q4",
            repo: "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF",
            displayName: "Qwen2.5 Coder 7B (GGUF)",
            family: "Qwen2.5 Coder",
            parameters: "7B",
            quantization: "Q4_K_M",
            diskBytes: 4_700_000_000,
            contextWindow: 32_768,
            minRAMGB: 12,
            recommendedRAMGB: 16,
            notes: "llama.cpp build — needs llama-server installed (brew install llama.cpp). Broadest quantization choice.",
            format: .gguf),
        CatalogModel(
            id: "qwen3-4b-gguf-q4",
            repo: "unsloth/Qwen3-4B-GGUF",
            displayName: "Qwen3 4B (GGUF)",
            family: "Qwen3",
            parameters: "4B",
            quantization: "Q4_K_M",
            diskBytes: 2_500_000_000,
            contextWindow: 32_768,
            minRAMGB: 8,
            recommendedRAMGB: 12,
            notes: "Fast GGUF generalist for 8–12 GB Macs. Runs via llama-server.",
            format: .gguf),
        CatalogModel(
            id: "qwen3-8b-gguf-q4",
            repo: "unsloth/Qwen3-8B-GGUF",
            displayName: "Qwen3 8B (GGUF)",
            family: "Qwen3",
            parameters: "8B",
            quantization: "Q4_K_M",
            diskBytes: 4_900_000_000,
            contextWindow: 32_768,
            minRAMGB: 12,
            recommendedRAMGB: 16,
            notes: "GGUF variant of the Qwen3 8B generalist. Runs via llama-server.",
            format: .gguf),

        // Vision sidecars (SmolVLM2, MLX VLM) — never loadable as the chat
        // engine; the app runs them automatically to describe image
        // attachments and simulator screenshots.
        CatalogModel(
            id: "smolvlm2-500m-mlx",
            repo: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            displayName: "SmolVLM2 500M",
            family: "SmolVLM2",
            parameters: "500M",
            quantization: "bf16",
            diskBytes: 1_020_000_000,
            contextWindow: 16_384,
            minRAMGB: 4,
            recommendedRAMGB: 6,
            notes: "Tiny vision sidecar. Describes screenshots and image attachments alongside any chat model.",
            role: .vision),
        CatalogModel(
            id: "smolvlm2-2.2b-mlx",
            repo: "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
            displayName: "SmolVLM2 2.2B",
            family: "SmolVLM2",
            parameters: "2.2B",
            quantization: "bf16",
            diskBytes: 4_500_000_000,
            contextWindow: 16_384,
            minRAMGB: 8,
            recommendedRAMGB: 12,
            notes: "Stronger vision sidecar — better UI/document reading. Needs real headroom next to a chat model.",
            role: .vision),
    ]

    private static var userCatalogURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeetCode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("UserModels.json")
    }

    static func loadUserModels() -> [CatalogModel] {
        guard let data = try? Data(contentsOf: userCatalogURL) else { return [] }
        do {
            let models = try JSONDecoder().decode([CatalogModel].self, from: data)
            let repaired = models.map(repairUserModel)
            if repaired != models { saveUserModels(repaired) }
            return repaired
        } catch {
            Log.app.error("User model catalog failed to decode: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Repairs entries imported by older builds when their managed copy is
    /// available. Never probe an arbitrary original import path here: catalog
    /// loading happens on app startup, and a disconnected external/network
    /// volume can block a synchronous `open` indefinitely.
    private static func repairUserModel(_ model: CatalogModel) -> CatalogModel {
        guard model.format == .mlx else { return model }

        let directory = userCatalogURL.deletingLastPathComponent()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("config.json").path),
              let metadata = MLXModelInspector.read(from: directory) else {
            return model
        }

        var repaired = model
        repaired.displayName = MLXModelInspector.displayName(for: directory, metadata: metadata)
        repaired.family = metadata.family
        repaired.parameters = metadata.parameters
        repaired.quantization = metadata.quantization
        repaired.contextWindow = metadata.contextWindow
        if metadata.isVisionLanguage {
            repaired.notes = "Imported multimodal MLX model (text + vision weights) from \(model.repo)"
        }
        return repaired
    }

    static func saveUserModels(_ models: [CatalogModel]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        try? data.write(to: userCatalogURL, options: .atomic)
    }

    static var all: [CatalogModel] {
        bundled + loadUserModels()
    }

    static func model(id: String) -> CatalogModel? {
        all.first { $0.id == id }
    }
}
