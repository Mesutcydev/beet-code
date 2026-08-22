import XCTest
@testable import BeetCode

final class DeviceProfileTests: XCTestCase {

    func testParsesChipBrandAndVariant() {
        let cases: [(String, Int, DeviceProfile.Variant)] = [
            ("Apple M1", 1, .base),
            ("Apple M1 Pro", 1, .pro),
            ("Apple M2 Max", 2, .max),
            ("Apple M3 Ultra", 3, .ultra),
            ("Apple M4 Pro", 4, .pro),
            ("Apple M5", 5, .base),
        ]
        for (brand, generation, variant) in cases {
            let parsed = DeviceProfile.parseChip(brand)
            XCTAssertEqual(parsed.generation, generation, brand)
            XCTAssertEqual(parsed.variant, variant, brand)
        }
    }

    func testUnknownBrandIsBaseGenerationZero() {
        let parsed = DeviceProfile.parseChip("VirtualApple @ 2.50GHz")
        XCTAssertEqual(parsed.generation, 0)
        XCTAssertEqual(parsed.variant, .base)
    }

    func testMarketedMemoryRoundsToAppleSKUs() {
        XCTAssertEqual(DeviceProfile.marketedMemoryGB(8 * gb1024), 8)
        XCTAssertEqual(DeviceProfile.marketedMemoryGB(16 * gb1024), 16)
        XCTAssertEqual(DeviceProfile.marketedMemoryGB(18 * gb1024), 18)
        XCTAssertEqual(DeviceProfile.marketedMemoryGB(36 * gb1024), 36)
        XCTAssertEqual(DeviceProfile.marketedMemoryGB(48 * gb1024 + 200 * 1_024 * 1_024), 48)
    }

    func testSummaryAndM1BandwidthDerate() {
        let m1Air16 = DeviceProfile.parse(brand: "Apple M1", memoryBytes: 16 * gb1024)
        XCTAssertEqual(m1Air16.chipLabel, "M1")
        XCTAssertEqual(m1Air16.summary, "M1 · 16 GB")
        XCTAssertEqual(m1Air16.recommendBudgetGB, 12)

        let m4Pro48 = DeviceProfile.parse(brand: "Apple M4 Pro", memoryBytes: 48 * gb1024)
        XCTAssertEqual(m4Pro48.chipLabel, "M4 Pro")
        XCTAssertEqual(m4Pro48.recommendBudgetGB, 48)
    }

    func testFitUsesMinAndRecommendedRAM() {
        let device = DeviceProfile.parse(brand: "Apple M3", memoryBytes: 16 * gb1024)
        let small = model(id: "s", min: 8, rec: 12, kind: .general)
        let daily = model(id: "d", min: 12, rec: 16, kind: .coding)
        let huge = model(id: "h", min: 32, rec: 36, kind: .coding)
        XCTAssertEqual(device.fit(small), .fits)
        XCTAssertEqual(device.fit(daily), .fits)
        XCTAssertEqual(device.fit(huge), .oversized)

        let tightDevice = DeviceProfile.parse(brand: "Apple M4", memoryBytes: 8 * gb1024)
        XCTAssertEqual(tightDevice.fit(small), .tight)
    }

    func testDailyPickByRAMTier() {
        let catalog = ModelCatalog.bundled

        XCTAssertEqual(
            CatalogLibrary.recommendedChat(
                from: catalog,
                device: DeviceProfile.parse(brand: "Apple M4", memoryBytes: 8 * gb1024))?.id,
            "qwen3-1.7b-4bit")
        XCTAssertEqual(
            CatalogLibrary.recommendedChat(
                from: catalog,
                device: DeviceProfile.parse(brand: "Apple M1", memoryBytes: 16 * gb1024))?.id,
            "qwen3.5-4b-4bit")
        XCTAssertEqual(
            CatalogLibrary.recommendedChat(
                from: catalog,
                device: DeviceProfile.parse(brand: "Apple M4", memoryBytes: 16 * gb1024))?.id,
            "qwen3.5-9b-4bit")
        XCTAssertEqual(
            CatalogLibrary.recommendedChat(
                from: catalog,
                device: DeviceProfile.parse(brand: "Apple M4 Pro", memoryBytes: 24 * gb1024))?.id,
            "qwen3-coder-14b-4bit")
        XCTAssertEqual(
            CatalogLibrary.recommendedChat(
                from: catalog,
                device: DeviceProfile.parse(brand: "Apple M4 Pro", memoryBytes: 32 * gb1024))?.id,
            "qwen3.5-27b-4bit")
        XCTAssertEqual(
            CatalogLibrary.recommendedChat(
                from: catalog,
                device: DeviceProfile.parse(brand: "Apple M4 Max", memoryBytes: 36 * gb1024))?.id,
            "qwen3.5-35b-a3b-4bit")
    }

    func testVisionPickFollowsRAM() {
        let catalog = ModelCatalog.bundled
        XCTAssertEqual(
            CatalogLibrary.recommendedVision(
                from: catalog,
                device: DeviceProfile.parse(brand: "Apple M4", memoryBytes: 16 * gb1024))?.id,
            "smolvlm2-500m-mlx")
        XCTAssertEqual(
            CatalogLibrary.recommendedVision(
                from: catalog,
                device: DeviceProfile.parse(brand: "Apple M4 Pro", memoryBytes: 24 * gb1024))?.id,
            "smolvlm2-2.2b-mlx")
    }

    func testCatalogsDifferByChipAndRAM() {
        let catalog = ModelCatalog.bundled
        func ids(_ brand: String, gb: UInt64, model: String = "") -> Set<String> {
            let device = DeviceProfile.parse(
                brand: brand, memoryBytes: gb * gb1024, modelIdentifier: model)
            return Set(CatalogLibrary.offered(from: catalog, device: device).map(\.id))
        }

        let m3air8 = ids("Apple M3", gb: 8)
        let m3air16 = ids("Apple M3", gb: 16)
        let m5air16 = ids("Apple M5", gb: 16)
        let m3pro36 = ids("Apple M3 Pro", gb: 36)
        let studio96 = ids("Apple M3 Ultra", gb: 96, model: "Mac14,14")

        XCTAssertNotEqual(m3air8, m3air16, "M3 8 GB and M3 16 GB must not share a list")
        XCTAssertNotEqual(m3air16, m5air16, "M5 16 GB sees 24 GB Pro picks that M3 16 GB does not")
        XCTAssertNotEqual(m3pro36, studio96, "Studio Ultra is not a 36 GB Pro list")

        XCTAssertTrue(m3air8.contains("nanbeige-4.1-3b-4bit"))
        XCTAssertTrue(m3air8.contains("nemotron-3-nano-4b-4bit"))
        XCTAssertFalse(m3air8.contains("ornith-1.5-9b-4bit"))
        XCTAssertFalse(m3air8.contains("llama-3.3-70b-4bit"))

        XCTAssertTrue(m3air16.contains("ornith-1.5-9b-4bit"))
        XCTAssertFalse(m3air16.contains("qwen3-coder-14b-4bit"))
        XCTAssertTrue(m5air16.contains("qwen3-coder-14b-4bit"))

        XCTAssertTrue(studio96.contains("ornith-1.0-35b-4bit"))
        XCTAssertTrue(studio96.contains("nemotron-3-super-120b-4bit"))
        XCTAssertTrue(studio96.contains("llama-3.3-70b-4bit"))
        XCTAssertFalse(studio96.contains("qwen3-1.7b-4bit"))
        XCTAssertFalse(studio96.contains("nanbeige-4.1-3b-4bit"))
    }

    func testBundledIncludesRequestedFamilies() {
        let families = Set(ModelCatalog.bundled.map(\.family))
        for family in ["Ornith", "Nanbeige", "NVIDIA Nemotron", "Llama", "Gemma 3", "Phi", "DeepSeek", "Mistral", "Qwen3.5"] {
            XCTAssertTrue(families.contains(family), "missing family \(family)")
        }
    }

    func testStudioIdentifierAndLane() {
        let studio = DeviceProfile.parse(
            brand: "Apple M2 Max", memoryBytes: 64 * gb1024, modelIdentifier: "Mac14,13")
        XCTAssertEqual(studio.productFamily, .studio)
        XCTAssertEqual(studio.lane, .studio)
        XCTAssertTrue(studio.summary.contains("Mac Studio"))

        let m3air = DeviceProfile.parse(brand: "Apple M3", memoryBytes: 16 * gb1024)
        XCTAssertEqual(m3air.lane, .air16)
        XCTAssertEqual(m3air.productFamily, .laptop)
        XCTAssertFalse(m3air.visibleLanes.contains(.pro24))

        let m5air = DeviceProfile.parse(brand: "Apple M5", memoryBytes: 16 * gb1024)
        XCTAssertTrue(m5air.visibleLanes.contains(.pro24))
    }

    func testM5SeriesCatalogsBySKU() {
        let catalog = ModelCatalog.bundled
        func profile(_ brand: String, gb: UInt64) -> DeviceProfile {
            DeviceProfile.parse(brand: brand, memoryBytes: gb * gb1024)
        }
        func ids(_ device: DeviceProfile) -> Set<String> {
            Set(CatalogLibrary.offered(from: catalog, device: device).map(\.id))
        }

        let air16 = profile("Apple M5", gb: 16)
        let air24 = profile("Apple M5", gb: 24)
        let air32 = profile("Apple M5", gb: 32)
        let pro24 = profile("Apple M5 Pro", gb: 24)
        let max64 = profile("Apple M5 Max", gb: 64)
        let m4air16 = profile("Apple M4", gb: 16)
        let m3pro24 = profile("Apple M3 Pro", gb: 24)

        XCTAssertEqual(air16.catalogCaption, "M5 Air · 16 GB catalog")
        XCTAssertEqual(air24.catalogCaption, "M5 Air · 24 GB catalog")
        XCTAssertEqual(air32.catalogCaption, "M5 Air · 32 GB catalog")
        XCTAssertEqual(pro24.catalogCaption, "M5 Pro · 24 GB catalog")
        XCTAssertEqual(max64.catalogCaption, "M5 Max · 64 GB catalog")
        XCTAssertEqual(air16.recommendBudgetGB, 24)
        XCTAssertEqual(air24.recommendBudgetGB, 32)

        XCTAssertTrue(ids(air16).contains("qwen3-coder-14b-4bit"))
        XCTAssertFalse(ids(m4air16).contains("qwen3-coder-14b-4bit"))
        XCTAssertEqual(
            CatalogLibrary.recommendedChat(from: catalog, device: air16)?.id,
            "qwen3-coder-14b-4bit")

        XCTAssertTrue(ids(air24).contains("qwen3.5-27b-4bit"))
        XCTAssertFalse(ids(m3pro24).contains("qwen3.5-27b-4bit"))
        XCTAssertEqual(
            CatalogLibrary.recommendedChat(from: catalog, device: air24)?.id,
            "qwen3.5-27b-4bit")

        XCTAssertTrue(ids(air32).contains("qwen3.5-35b-a3b-4bit"))
        XCTAssertTrue(ids(pro24).contains("qwen3.5-27b-4bit"))
        XCTAssertTrue(ids(max64).contains("llama-3.3-70b-4bit"))
        XCTAssertTrue(ids(max64).contains("nemotron-3-super-120b-4bit"))
    }

    func testBundledCatalogIsWellFormedForDeviceTiers() {
        let ids = ModelCatalog.bundled.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "catalog IDs must be unique")
        for model in ModelCatalog.bundled {
            XCTAssertFalse(model.repo.isEmpty, model.id)
            XCTAssertGreaterThan(model.diskBytes, 0, model.id)
            XCTAssertLessThanOrEqual(model.minRAMGB, model.recommendedRAMGB, model.id)
            XCTAssertGreaterThan(model.contextWindow, 0, model.id)
            if model.role == .vision {
                XCTAssertEqual(model.kind, .vision, model.id)
            }
        }
        XCTAssertNotNil(ModelCatalog.model(id: "qwen3.5-9b-4bit"))
        XCTAssertEqual(
            ModelCatalog.model(id: "qwen3-coder-14b-4bit")?.repo,
            "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit")
    }

    func testKindInfersFromFamilyWhenMissing() throws {
        let json = """
            [{"id":"old-coder","repo":"a/b","displayName":"Old","family":"Qwen2.5 Coder",
              "parameters":"7B","quantization":"4-bit","diskBytes":1000,
              "contextWindow":32768,"minRAMGB":12,"recommendedRAMGB":16,
              "notes":"legacy"}]
            """
        let models = try JSONDecoder().decode([CatalogModel].self, from: Data(json.utf8))
        XCTAssertEqual(models.first?.kind, .coding)
    }

    func testCurrentProfileReadsThisMac() {
        let live = DeviceProfile.current()
        XCTAssertGreaterThan(live.memoryGB, 0)
        XCTAssertFalse(live.summary.isEmpty)
    }

    private func model(id: String, min: Int, rec: Int, kind: CatalogModel.Kind) -> CatalogModel {
        CatalogModel(
            id: id, repo: "test/\(id)", displayName: id, family: "Test",
            parameters: "1B", quantization: "4-bit", diskBytes: 1_000_000,
            contextWindow: 8_192, minRAMGB: min, recommendedRAMGB: rec,
            notes: "", kind: kind)
    }

    private var gb1024: UInt64 { 1_024 * 1_024 * 1_024 }
}
