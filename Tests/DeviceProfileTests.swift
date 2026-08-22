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

    func testSectionsLeadWithRecommendedAndKeepEveryModel() {
        let device = DeviceProfile.parse(brand: "Apple M4", memoryBytes: 16 * gb1024)
        let sections = CatalogLibrary.sections(from: ModelCatalog.bundled, device: device)
        XCTAssertEqual(sections.first?.id, .recommended)
        XCTAssertTrue(sections.contains { $0.id == .oversized })
        let listed = Set(sections.flatMap(\.models).map(\.id))
        XCTAssertEqual(listed, Set(ModelCatalog.bundled.map(\.id)))
        XCTAssertTrue(CatalogLibrary.recommendedIDs(from: ModelCatalog.bundled, device: device)
            .contains("qwen3.5-9b-4bit"))
        XCTAssertTrue(CatalogLibrary.recommendedIDs(from: ModelCatalog.bundled, device: device)
            .contains("qwen3.5-9b-gguf-q4"))
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
