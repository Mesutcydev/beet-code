import Darwin
import Foundation

/// Which curated catalog a Mac sees. An 8 GB M3 Air, a 16 GB M5, a 36 GB
/// M3 Pro, and a Studio Ultra are different machines — they get different
/// lists, not one ranked dump.
enum DeviceLane: String, Codable, Sendable, CaseIterable, Comparable {
    case air8
    case air16
    case pro24
    case pro36
    case max
    case studio

    var rank: Int {
        switch self {
        case .air8: 0
        case .air16: 1
        case .pro24: 2
        case .pro36: 3
        case .max: 4
        case .studio: 5
        }
    }

    var catalogTitle: String {
        switch self {
        case .air8: "8 GB catalog"
        case .air16: "16 GB catalog"
        case .pro24: "24 GB Pro catalog"
        case .pro36: "32–36 GB Pro catalog"
        case .max: "Max catalog"
        case .studio: "Studio / Ultra catalog"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Default lanes from a model's recommended RAM, used when an older
    /// catalog file has no `lanes` key.
    static func inferred(recommendedRAMGB: Int, role: CatalogModel.Role) -> [DeviceLane] {
        if role == .vision {
            return recommendedRAMGB <= 8 ? [.air8, .air16] : [.pro24, .pro36, .max, .studio]
        }
        switch recommendedRAMGB {
        case ...8: return [.air8]
        case ...16: return [.air8, .air16]
        case ...24: return [.air16, .pro24]
        case ...36: return [.pro24, .pro36]
        case ...64: return [.pro36, .max]
        default: return [.max, .studio]
        }
    }
}

enum ProductFamily: String, Sendable, Equatable {
    case laptop
    case studio
}

/// This Mac's Apple Silicon identity: chip generation, variant, unified
/// memory, and product family (Studio vs laptop).
struct DeviceProfile: Equatable, Sendable, Hashable {
    enum Variant: String, Sendable, Comparable {
        case base
        case pro
        case max
        case ultra

        var displayName: String {
            switch self {
            case .base: ""
            case .pro: "Pro"
            case .max: "Max"
            case .ultra: "Ultra"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

        private var rank: Int {
            switch self {
            case .base: 0
            case .pro: 1
            case .max: 2
            case .ultra: 3
            }
        }
    }

    enum Fit: String, Sendable, Equatable {
        case fits
        case tight
        case oversized
    }

    let brandName: String
    let generationNumber: Int
    let variant: Variant
    let memoryGB: Int
    let modelIdentifier: String
    let productFamily: ProductFamily

    var isAppleSilicon: Bool {
        generationNumber > 0 || brandName.localizedCaseInsensitiveContains("Apple")
    }

    var chipLabel: String {
        guard generationNumber > 0 else { return brandName }
        let base = "M\(generationNumber)"
        return variant == .base ? base : "\(base) \(variant.displayName)"
    }

    var summary: String {
        switch productFamily {
        case .studio: "Mac Studio · \(chipLabel) · \(memoryGB) GB"
        case .laptop: "\(chipLabel) · \(memoryGB) GB"
        }
    }

    var catalogCaption: String {
        if generationNumber >= 5, lane == .air16 {
            return "M5 · 16 GB catalog (includes 24 GB Pro picks)"
        }
        if productFamily == .studio { return DeviceLane.studio.catalogTitle }
        return lane.catalogTitle
    }

    /// RAM the catalog should treat as the comfortable daily-driver budget.
    /// M1 base 16 GB is scored as 12 GB (bandwidth). M5 keeps its full RAM.
    var recommendBudgetGB: Int {
        if variant == .base && generationNumber <= 1 && memoryGB >= 16 {
            return 12
        }
        return memoryGB
    }

    var lane: DeviceLane {
        if variant == .ultra || memoryGB >= 96 { return .studio }
        if productFamily == .studio && memoryGB >= 64 { return .studio }
        if variant == .max || memoryGB >= 48 { return .max }
        if memoryGB >= 32 { return .pro36 }
        if memoryGB >= 18 { return .pro24 }
        if memoryGB >= 12 { return .air16 }
        return .air8
    }

    /// Lanes whose models appear in this Mac's list.
    ///
    /// M5 16 GB also sees the 24 GB Pro set (higher bandwidth). M3 16 GB
    /// does not. Studio also sees Max step-downs. Pro/Max see one class
    /// smaller so a 36 GB Pro still has the 24 GB daily drivers.
    var visibleLanes: Set<DeviceLane> {
        var set: Set<DeviceLane> = [lane]
        switch lane {
        case .air8:
            break
        case .air16:
            if generationNumber >= 5 { set.insert(.pro24) }
        case .pro24:
            set.insert(.air16)
        case .pro36:
            set.insert(.pro24)
        case .max:
            set.insert(.pro36)
        case .studio:
            set.insert(.max)
        }
        return set
    }

    func fit(_ model: CatalogModel) -> Fit {
        if memoryGB < model.minRAMGB { return .oversized }
        if memoryGB < model.recommendedRAMGB { return .tight }
        return .fits
    }

    static func current() -> DeviceProfile {
        parse(
            brand: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            modelIdentifier: sysctlString("hw.model") ?? "")
    }

    static func parse(
        brand: String,
        memoryBytes: UInt64,
        modelIdentifier: String = ""
    ) -> DeviceProfile {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let (generation, variant) = parseChip(trimmed)
        let identifier = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return DeviceProfile(
            brandName: trimmed.isEmpty ? "Apple Silicon" : trimmed,
            generationNumber: generation,
            variant: variant,
            memoryGB: marketedMemoryGB(memoryBytes),
            modelIdentifier: identifier,
            productFamily: isStudioIdentifier(identifier) || variant == .ultra ? .studio : .laptop)
    }

    static func marketedMemoryGB(_ bytes: UInt64) -> Int {
        guard bytes > 0 else { return 0 }
        let raw = Int((bytes + 512 * 1_024 * 1_024) / (1_024 * 1_024 * 1_024))
        let skus = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512]
        return skus.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? raw
    }

    static func parseChip(_ brand: String) -> (generation: Int, variant: Variant) {
        let pattern = #"Apple\s+M(\d+)\s*(Pro|Max|Ultra)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: brand, range: NSRange(brand.startIndex..., in: brand)),
              match.numberOfRanges >= 2,
              let genRange = Range(match.range(at: 1), in: brand),
              let generation = Int(brand[genRange])
        else { return (0, .base) }

        var variant = Variant.base
        if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound,
           let variantRange = Range(match.range(at: 2), in: brand) {
            switch brand[variantRange].lowercased() {
            case "pro": variant = .pro
            case "max": variant = .max
            case "ultra": variant = .ultra
            default: break
            }
        }
        return (generation, variant)
    }

    /// Known Mac Studio `hw.model` IDs (M1–M4). Ultra chips also count as
    /// Studio-class even when the identifier is a Mac Pro.
    static func isStudioIdentifier(_ identifier: String) -> Bool {
        let known: Set<String> = [
            "Mac13,1", "Mac13,2",
            "Mac14,13", "Mac14,14",
            "Mac15,14", "Mac16,9", "Mac16,10",
        ]
        return known.contains(identifier)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        if let terminator = buffer.firstIndex(of: 0) {
            buffer = Array(buffer[..<terminator])
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}

extension CatalogModel {
    func isOffered(on device: DeviceProfile) -> Bool {
        if lanes.isEmpty { return true }
        return lanes.contains { device.visibleLanes.contains($0) }
    }
}

enum CatalogLibrary {
    struct Section: Identifiable, Equatable, Sendable {
        enum ID: String, Sendable {
            case recommended
            case fits
            case tight
            case oversized
        }

        let id: ID
        let models: [CatalogModel]

        var title: String {
            switch id {
            case .recommended: "Recommended for this Mac"
            case .fits: "Fits this Mac"
            case .tight: "Tight on this Mac"
            case .oversized: "Needs more memory"
            }
        }

        var systemImage: String {
            switch id {
            case .recommended: "star.fill"
            case .fits: "checkmark.circle"
            case .tight: "exclamationmark.triangle"
            case .oversized: "memorychip"
            }
        }
    }

    static func offered(
        from models: [CatalogModel],
        device: DeviceProfile,
        keepIDs: Set<String> = []
    ) -> [CatalogModel] {
        models.filter { keepIDs.contains($0.id) || $0.isOffered(on: device) }
    }

    static func recommendedChat(
        from models: [CatalogModel] = ModelCatalog.all,
        device: DeviceProfile
    ) -> CatalogModel? {
        let chat = offered(from: models, device: device)
            .filter { $0.role == .chat && $0.format == .mlx }
        let budget = device.recommendBudgetGB
        let comfortable = chat.filter { $0.recommendedRAMGB <= budget }
        let candidates = comfortable.isEmpty
            ? chat.filter { $0.minRAMGB <= device.memoryGB }
            : comfortable
        return candidates.max(by: { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind != .coding && rhs.kind == .coding }
            if lhs.recommendedRAMGB != rhs.recommendedRAMGB {
                return lhs.recommendedRAMGB < rhs.recommendedRAMGB
            }
            let leftCurrent = lhs.family.contains("3.5") || lhs.family.contains("Ornith")
            let rightCurrent = rhs.family.contains("3.5") || rhs.family.contains("Ornith")
            if leftCurrent != rightCurrent { return !leftCurrent && rightCurrent }
            return lhs.diskBytes < rhs.diskBytes
        })
    }

    static func recommendedVision(
        from models: [CatalogModel] = ModelCatalog.all,
        device: DeviceProfile
    ) -> CatalogModel? {
        let vision = offered(from: models, device: device).filter { $0.role == .vision }
        let pick = device.memoryGB >= 24
            ? vision.max(by: { $0.diskBytes < $1.diskBytes })
            : vision.min(by: { $0.diskBytes < $1.diskBytes })
        guard let pick, device.fit(pick) != .oversized else { return nil }
        return pick
    }

    static func recommendedIDs(
        from models: [CatalogModel] = ModelCatalog.all,
        device: DeviceProfile
    ) -> Set<String> {
        var ids = Set<String>()
        if let chat = recommendedChat(from: models, device: device) {
            ids.insert(chat.id)
            if let twin = offered(from: models, device: device).first(where: {
                $0.format == .gguf
                    && $0.role == .chat
                    && $0.family == chat.family
                    && $0.parameters == chat.parameters
                    && device.fit($0) != .oversized
            }) {
                ids.insert(twin.id)
            }
        }
        if let vision = recommendedVision(from: models, device: device) {
            ids.insert(vision.id)
        }
        return ids
    }

    static func sections(
        from models: [CatalogModel] = ModelCatalog.all,
        device: DeviceProfile,
        keepIDs: Set<String> = []
    ) -> [Section] {
        let visible = offered(from: models, device: device, keepIDs: keepIDs)
        let recommended = recommendedIDs(from: models, device: device)
        var rec: [CatalogModel] = []
        var fits: [CatalogModel] = []
        var tight: [CatalogModel] = []
        var oversized: [CatalogModel] = []

        for model in visible {
            if recommended.contains(model.id) {
                rec.append(model)
                continue
            }
            switch device.fit(model) {
            case .fits: fits.append(model)
            case .tight: tight.append(model)
            case .oversized: oversized.append(model)
            }
        }

        return [
            Section(id: .recommended, models: rec),
            Section(id: .fits, models: fits),
            Section(id: .tight, models: tight),
            Section(id: .oversized, models: oversized),
        ].filter { !$0.models.isEmpty }
    }
}
