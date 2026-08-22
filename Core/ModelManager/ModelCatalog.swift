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

    /// How the catalog ranks a chat model for a given Mac. Vision sidecars
    /// are always `.vision`; coding-tuned weights win the daily-driver pick.
    enum Kind: String, Codable, Sendable {
        case coding
        case general
        case vision

        static func inferred(family: String, role: Role, id: String) -> Kind {
            if role == .vision { return .vision }
            let haystack = "\(family) \(id)".lowercased()
            if haystack.contains("coder")
                || haystack.contains("ornith")
                || haystack.contains("devstral") {
                return .coding
            }
            return .general
        }
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
    var kind: Kind = .general
    /// Empty means "every Mac" (user imports). Bundled entries name the
    /// device lanes that should see this checkpoint.
    var lanes: [DeviceLane] = []

    /// Tolerant decoding: catalog files written by older builds lack
    /// `format`/`role`/`kind`/`lanes` — fill defaults instead of dropping the file.
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
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind)
            ?? Kind.inferred(family: family, role: role, id: id)
        lanes = try c.decodeIfPresent([DeviceLane].self, forKey: .lanes)
            ?? DeviceLane.inferred(recommendedRAMGB: recommendedRAMGB, role: role)
    }

    init(
        id: String, repo: String, displayName: String, family: String,
        parameters: String, quantization: String, diskBytes: Int64,
        contextWindow: Int, minRAMGB: Int, recommendedRAMGB: Int,
        notes: String, format: Format = .mlx, role: Role = .chat,
        kind: Kind? = nil, lanes: [DeviceLane]? = nil
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
        self.kind = kind ?? Kind.inferred(family: family, role: role, id: id)
        self.lanes = lanes ?? DeviceLane.inferred(recommendedRAMGB: recommendedRAMGB, role: role)
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

    private static func catalogEntry(
        id: String, repo: String, name: String, family: String, params: String,
        bytes: Int64, ctx: Int = 32_768, min: Int, rec: Int, notes: String,
        quant: String = "4-bit", format: CatalogModel.Format = .mlx,
        role: CatalogModel.Role = .chat, kind: CatalogModel.Kind? = nil,
        lanes: [DeviceLane]
    ) -> CatalogModel {
        CatalogModel(
            id: id, repo: repo, displayName: name, family: family,
            parameters: params, quantization: quant, diskBytes: bytes,
            contextWindow: ctx, minRAMGB: min, recommendedRAMGB: rec,
            notes: notes, format: format, role: role, kind: kind, lanes: lanes)
    }

    /// Curated by family and device lane. `CatalogLibrary` shows only the
    /// lanes that match this Mac (M3 8 GB ≠ M5 16 GB ≠ Studio Ultra).
    static let bundled: [CatalogModel] = [
        // MARK: Qwen — coding agent line
        catalogEntry(id: "qwen3-1.7b-4bit", repo: "mlx-community/Qwen3-1.7B-4bit",
              name: "Qwen3 1.7B", family: "Qwen3", params: "1.7B",
              bytes: 1_100_000_000, min: 6, rec: 8,
              notes: "8 GB starter. Fast enough to try the agent; limited coding depth.",
              kind: .coding, lanes: [.air8]),
        catalogEntry(id: "qwen3.5-4b-4bit", repo: "mlx-community/Qwen3.5-4B-4bit",
              name: "Qwen3.5 4B", family: "Qwen3.5", params: "4B",
              bytes: 3_054_000_000, ctx: 262_144, min: 8, rec: 12,
              notes: "8–16 GB Qwen daily driver. Stronger tool use than Qwen3 4B.",
              kind: .coding, lanes: [.air8, .air16]),
        catalogEntry(id: "qwen3-4b-4bit", repo: "mlx-community/Qwen3-4B-4bit",
              name: "Qwen3 4B", family: "Qwen3", params: "4B",
              bytes: 2_400_000_000, min: 8, rec: 12,
              notes: "Previous-generation 4B. Smaller download than Qwen3.5 4B.",
              lanes: [.air8, .air16]),
        catalogEntry(id: "qwen3.5-9b-4bit", repo: "mlx-community/Qwen3.5-9B-4bit",
              name: "Qwen3.5 9B", family: "Qwen3.5", params: "9B",
              bytes: 5_970_000_000, ctx: 262_144, min: 12, rec: 18,
              notes: "Runs on M4 16 GB as a tight configuration. Close memory-heavy apps and use active cooling for sustained generation.",
              kind: .coding, lanes: [.air16]),
        catalogEntry(id: "qwen2.5-coder-7b-4bit", repo: "mlx-community/Qwen2.5-Coder-7B-4bit",
              name: "Qwen2.5 Coder 7B", family: "Qwen2.5 Coder", params: "7B",
              bytes: 4_100_000_000, min: 12, rec: 16,
              notes: "Dedicated 7B coder. Prefer Qwen3.5 9B or Ornith 9B unless you want the smaller coder.",
              lanes: [.air16]),
        catalogEntry(id: "qwen3-8b-4bit", repo: "mlx-community/Qwen3-8B-4bit",
              name: "Qwen3 8B", family: "Qwen3", params: "8B",
              bytes: 4_900_000_000, min: 12, rec: 16,
              notes: "Previous-generation 8B generalist.",
              lanes: [.air16]),
        catalogEntry(id: "qwen3-coder-14b-4bit", repo: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit",
              name: "Qwen2.5 Coder 14B", family: "Qwen2.5 Coder", params: "14B",
              bytes: 9_000_000_000, ctx: 65_536, min: 18, rec: 24,
              notes: "24 GB Pro coder. M5 16 GB can see this as a tight pick; M3 16 GB cannot.",
              lanes: [.pro24]),
        catalogEntry(id: "qwen3.5-27b-4bit", repo: "mlx-community/Qwen3.5-27B-4bit",
              name: "Qwen3.5 27B", family: "Qwen3.5", params: "27B",
              bytes: 16_075_000_000, ctx: 262_144, min: 24, rec: 32,
              notes: "Dense 27B for 32 GB Pro. Tight on 24 GB.",
              kind: .coding, lanes: [.pro36]),
        catalogEntry(id: "qwen3-coder-30b-a3b-4bit", repo: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
              name: "Qwen3 Coder 30B A3B", family: "Qwen3 Coder", params: "30B (3B active)",
              bytes: 17_000_000_000, ctx: 65_536, min: 24, rec: 32,
              notes: "MoE coder: 30B quality at near-8B decode.",
              lanes: [.pro36]),
        catalogEntry(id: "qwen3.5-35b-a3b-4bit", repo: "mlx-community/Qwen3.5-35B-A3B-4bit",
              name: "Qwen3.5 35B A3B", family: "Qwen3.5", params: "35B (3B active)",
              bytes: 20_412_000_000, ctx: 262_144, min: 32, rec: 36,
              notes: "MoE daily driver for 36 GB Pro/Max.",
              kind: .coding, lanes: [.pro36, .max]),
        catalogEntry(id: "qwen3.5-122b-a10b-4bit", repo: "mlx-community/Qwen3.5-122B-A10B-4bit",
              name: "Qwen3.5 122B A10B", family: "Qwen3.5", params: "122B (10B active)",
              bytes: 69_614_000_000, ctx: 262_144, min: 80, rec: 96,
              notes: "Studio / Ultra flagship. Needs ~96 GB unified memory.",
              kind: .coding, lanes: [.studio]),

        // MARK: Ornith — agentic coding (Qwen3.5 architecture)
        catalogEntry(id: "ornith-1.5-9b-4bit", repo: "ornith-ai/Ornith-1.5-9B-MLX-4bit",
              name: "Ornith 1.5 9B", family: "Ornith", params: "9B",
              bytes: 5_061_000_000, ctx: 262_144, min: 12, rec: 16,
              notes: "Ornith 1.5 dense 9B. Agentic coder for 16 GB; Qwen3.5 architecture so it loads in-process.",
              kind: .coding, lanes: [.air16, .pro24]),
        catalogEntry(id: "ornith-1.5-35b-a3b-4bit", repo: "ornith-ai/Ornith-1.5-35B-A3B-MLX-4bit",
              name: "Ornith 1.5 35B A3B", family: "Ornith", params: "35B (3B active)",
              bytes: 19_531_000_000, ctx: 262_144, min: 32, rec: 36,
              notes: "Ornith 1.5 MoE. Strong 36 GB+ agentic coder; 3B active per token.",
              kind: .coding, lanes: [.pro36, .max]),
        catalogEntry(id: "ornith-1.0-35b-4bit", repo: "Brooooooklyn/Ornith-1.0-35B-UD-Q4_K_XL-mlx",
              name: "Ornith 1.0 35B", family: "Ornith", params: "35B (3B active)",
              bytes: 22_557_000_000, ctx: 262_144, min: 36, rec: 48,
              notes: "Ornith 1.0 UD-Q4 for Max / Studio. Previous-generation Ornith if you already use 1.0 recipes.",
              kind: .coding, lanes: [.max, .studio]),

        // MARK: Nanbeige — looped 3B (llama-type 4.1 loads in mlx-swift)
        catalogEntry(id: "nanbeige-4.1-3b-4bit", repo: "mlx-community/Nanbeige4.1-3B-4bit",
              name: "Nanbeige 4.1 3B", family: "Nanbeige", params: "3B",
              bytes: 2_231_000_000, min: 6, rec: 8,
              notes: "Nanbeige 4.1 3B (BOSS Zhipin). Llama-type checkpoint — works on 8 GB. Strong tool calling for its size.",
              lanes: [.air8, .air16]),
        catalogEntry(id: "nanbeige-4.1-3b-8bit", repo: "mlx-community/Nanbeige4.1-3B-8bit",
              name: "Nanbeige 4.1 3B 8-bit", family: "Nanbeige", params: "3B",
              bytes: 4_198_000_000, min: 8, rec: 12,
              notes: "Higher-quality 8-bit Nanbeige 4.1 for 16 GB when you want less quant loss.",
              quant: "8-bit", lanes: [.air16]),

        // MARK: NVIDIA Nemotron — nemotron_h (supported by mlx-swift-lm)
        catalogEntry(id: "nemotron-3-nano-4b-4bit", repo: "mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit",
              name: "Nemotron 3 Nano 4B", family: "NVIDIA Nemotron", params: "4B",
              bytes: 2_254_000_000, min: 6, rec: 8,
              notes: "NVIDIA Nemotron 3 Nano 4B. Hybrid Mamba-2/attention; light 8–16 GB generalist.",
              lanes: [.air8, .air16]),
        catalogEntry(id: "nemotron-3-nano-30b-a3b-4bit", repo: "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit",
              name: "Nemotron 3 Nano 30B A3B", family: "NVIDIA Nemotron", params: "30B (3B active)",
              bytes: 17_793_000_000, min: 24, rec: 32,
              notes: "Nemotron 3 Nano MoE. 32 GB Pro alternative to Qwen3.5 27B.",
              kind: .coding, lanes: [.pro36]),
        catalogEntry(id: "nemotron-3.5-lightning-30b-4bit", repo: "mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit",
              name: "Nemotron 3.5 Lightning 30B", family: "NVIDIA Nemotron", params: "30B (3B active)",
              bytes: 17_793_000_000, min: 24, rec: 32,
              notes: "NVIDIA Nemotron 3.5 Lightning. Current Nemotron MoE for 32–36 GB Pro/Max.",
              kind: .coding, lanes: [.pro36, .max]),
        catalogEntry(id: "nemotron-3-super-120b-4bit", repo: "mlx-community/NVIDIA-Nemotron-3-Super-120B-A12B-4bit",
              name: "Nemotron 3 Super 120B", family: "NVIDIA Nemotron", params: "120B (12B active)",
              bytes: 68_018_000_000, min: 80, rec: 96,
              notes: "Studio / Ultra Nemotron Super. ~68 GB on disk, 96 GB unified memory.",
              kind: .coding, lanes: [.studio]),

        // MARK: Llama
        catalogEntry(id: "llama-3.2-1b-4bit", repo: "mlx-community/Llama-3.2-1B-Instruct-4bit",
              name: "Llama 3.2 1B", family: "Llama", params: "1B",
              bytes: 1_408_000_000, min: 6, rec: 8,
              notes: "Tiny Llama for 8 GB. Chat/general, not a coding specialist.",
              lanes: [.air8]),
        catalogEntry(id: "llama-3.1-8b-4bit", repo: "mlx-community/Llama-3.1-8B-Instruct-4bit",
              name: "Llama 3.1 8B", family: "Llama", params: "8B",
              bytes: 4_535_000_000, ctx: 131_072, min: 12, rec: 16,
              notes: "Meta Llama 3.1 8B Instruct. 16 GB generalist alongside Qwen/Ornith.",
              lanes: [.air16]),
        catalogEntry(id: "llama-3.3-70b-4bit", repo: "mlx-community/Llama-3.3-70B-Instruct-4bit",
              name: "Llama 3.3 70B", family: "Llama", params: "70B",
              bytes: 39_706_000_000, ctx: 131_072, min: 64, rec: 96,
              notes: "Dense 70B for Studio / 96 GB Ultra. ~40 GB download.",
              lanes: [.studio]),

        // MARK: Gemma
        catalogEntry(id: "gemma-3-1b-4bit", repo: "mlx-community/gemma-3-1b-it-4bit",
              name: "Gemma 3 1B", family: "Gemma 3", params: "1B",
              bytes: 771_000_000, min: 6, rec: 8,
              notes: "Google Gemma 3 1B IT. Smallest Gemma; 8 GB only.",
              lanes: [.air8]),
        catalogEntry(id: "gemma-3-12b-4bit", repo: "mlx-community/gemma-3-12b-it-4bit",
              name: "Gemma 3 12B", family: "Gemma 3", params: "12B",
              bytes: 16_095_000_000, ctx: 131_072, min: 24, rec: 32,
              notes: "Gemma 3 12B IT. Vision-capable weights; 32 GB Pro class.",
              lanes: [.pro36, .max]),
        catalogEntry(id: "gemma-3-27b-4bit", repo: "mlx-community/gemma-3-27b-it-4bit",
              name: "Gemma 3 27B", family: "Gemma 3", params: "27B",
              bytes: 33_706_000_000, ctx: 131_072, min: 48, rec: 64,
              notes: "Gemma 3 27B IT for Max / Studio. ~34 GB on disk.",
              lanes: [.max, .studio]),

        // MARK: Phi
        catalogEntry(id: "phi-4-mini-4bit", repo: "mlx-community/Phi-4-mini-instruct-4bit",
              name: "Phi-4 mini", family: "Phi", params: "3.8B",
              bytes: 2_174_000_000, min: 6, rec: 8,
              notes: "Microsoft Phi-4 mini. Compact 8–16 GB reasoner.",
              lanes: [.air8, .air16]),
        catalogEntry(id: "phi-4-4bit", repo: "mlx-community/phi-4-4bit",
              name: "Phi-4 14B", family: "Phi", params: "14B",
              bytes: 8_247_000_000, min: 18, rec: 24,
              notes: "Phi-4 14B for 24 GB Pro.",
              lanes: [.pro24]),

        // MARK: DeepSeek
        catalogEntry(id: "deepseek-r1-llama-8b-4bit", repo: "mlx-community/DeepSeek-R1-Distill-Llama-8B-4bit",
              name: "DeepSeek R1 Distill 8B", family: "DeepSeek", params: "8B",
              bytes: 4_535_000_000, min: 12, rec: 16,
              notes: "DeepSeek R1 distilled onto Llama 8B. Reasoning on 16 GB.",
              lanes: [.air16]),
        catalogEntry(id: "deepseek-r1-14b-4bit", repo: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit",
              name: "DeepSeek R1 Distill 14B", family: "DeepSeek", params: "14B",
              bytes: 8_321_000_000, min: 18, rec: 24,
              notes: "DeepSeek R1 14B distill for 24 GB Pro.",
              lanes: [.pro24]),
        catalogEntry(id: "deepseek-r1-32b-4bit", repo: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit",
              name: "DeepSeek R1 Distill 32B", family: "DeepSeek", params: "32B",
              bytes: 18_443_000_000, min: 32, rec: 36,
              notes: "DeepSeek R1 32B distill for 36 GB Pro / Max.",
              lanes: [.pro36, .max]),

        // MARK: Mistral / Devstral
        catalogEntry(id: "devstral-small-2507-4bit", repo: "mlx-community/Devstral-Small-2507-4bit",
              name: "Devstral Small 2507", family: "Mistral", params: "24B",
              bytes: 13_277_000_000, ctx: 131_072, min: 24, rec: 32,
              notes: "Mistral Devstral Small — coding-tuned 24B for 32 GB Pro.",
              kind: .coding, lanes: [.pro36, .max]),
        catalogEntry(id: "mistral-small-3.1-24b-4bit", repo: "mlx-community/Mistral-Small-3.1-24B-Instruct-2503-4bit",
              name: "Mistral Small 3.1 24B", family: "Mistral", params: "24B",
              bytes: 14_119_000_000, ctx: 131_072, min: 24, rec: 32,
              notes: "Mistral Small 3.1 Instruct. General 32 GB Pro model.",
              lanes: [.pro36]),

        // MARK: GGUF fallbacks
        catalogEntry(id: "qwen3.5-4b-gguf-q4", repo: "unsloth/Qwen3.5-4B-GGUF",
              name: "Qwen3.5 4B (GGUF)", family: "Qwen3.5", params: "4B",
              bytes: 2_800_000_000, ctx: 262_144, min: 8, rec: 12,
              notes: "llama.cpp twin of Qwen3.5 4B. Needs brew install llama.cpp.",
              quant: "Q4_K_M", format: .gguf, kind: .coding, lanes: [.air8, .air16]),
        catalogEntry(id: "qwen3.5-9b-gguf-q4", repo: "unsloth/Qwen3.5-9B-GGUF",
              name: "Qwen3.5 9B (GGUF)", family: "Qwen3.5", params: "9B",
              bytes: 5_800_000_000, ctx: 262_144, min: 12, rec: 16,
              notes: "llama.cpp twin of Qwen3.5 9B.",
              quant: "Q4_K_M", format: .gguf, kind: .coding, lanes: [.air16]),
        catalogEntry(id: "qwen2.5-coder-7b-gguf-q4", repo: "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF",
              name: "Qwen2.5 Coder 7B (GGUF)", family: "Qwen2.5 Coder", params: "7B",
              bytes: 4_700_000_000, min: 12, rec: 16,
              notes: "llama.cpp coder for 16 GB.",
              quant: "Q4_K_M", format: .gguf, lanes: [.air16]),
        catalogEntry(id: "qwen3-4b-gguf-q4", repo: "unsloth/Qwen3-4B-GGUF",
              name: "Qwen3 4B (GGUF)", family: "Qwen3", params: "4B",
              bytes: 2_500_000_000, min: 8, rec: 12,
              notes: "Previous-generation GGUF 4B.",
              quant: "Q4_K_M", format: .gguf, lanes: [.air8, .air16]),
        catalogEntry(id: "qwen3-8b-gguf-q4", repo: "unsloth/Qwen3-8B-GGUF",
              name: "Qwen3 8B (GGUF)", family: "Qwen3", params: "8B",
              bytes: 4_900_000_000, min: 12, rec: 16,
              notes: "Previous-generation GGUF 8B.",
              quant: "Q4_K_M", format: .gguf, lanes: [.air16]),

        // MARK: Vision sidecars
        catalogEntry(id: "smolvlm2-500m-mlx", repo: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
              name: "SmolVLM2 500M", family: "SmolVLM2", params: "500M",
              bytes: 1_020_000_000, ctx: 16_384, min: 4, rec: 6,
              notes: "Vision sidecar for 8–16 GB. Describes screenshots beside any chat model.",
              quant: "bf16", role: .vision, lanes: [.air8, .air16]),
        catalogEntry(id: "smolvlm2-2.2b-mlx", repo: "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
              name: "SmolVLM2 2.2B", family: "SmolVLM2", params: "2.2B",
              bytes: 4_500_000_000, ctx: 16_384, min: 8, rec: 12,
              notes: "Stronger vision sidecar for 24 GB+.",
              quant: "bf16", role: .vision, lanes: [.pro24, .pro36, .max, .studio]),
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
