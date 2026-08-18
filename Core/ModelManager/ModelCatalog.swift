import Foundation

/// A model entry the app knows how to download and run. The bundled list is
/// curated for Apple Silicon RAM tiers; users can add arbitrary HF repos,
/// which land in the user catalog file with defaults filled in.
struct CatalogModel: Codable, Identifiable, Sendable, Hashable {
    enum Format: String, Codable, Sendable {
        case mlx
        case gguf
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

    var subtitle: String {
        "\(parameters) · \(quantization) · ~\(ByteFormatter.bytes(diskBytes))"
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
            return try JSONDecoder().decode([CatalogModel].self, from: data)
        } catch {
            Log.app.error("User model catalog failed to decode: \(String(describing: error), privacy: .public)")
            return []
        }
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
