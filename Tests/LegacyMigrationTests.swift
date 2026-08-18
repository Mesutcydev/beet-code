import XCTest
@testable import BeetCode

/// Folder migration is the pure, testable half of LegacyMigration (Keychain
/// work is verified manually — XCTest never touches the real Keychain).
final class LegacyMigrationTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFolder(_ name: String, file: String = "data.json") throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return dir
    }

    func testMoveWhenLegacyExistsAndNewDoesNot() throws {
        let legacy = try makeFolder("LocalForge")
        let new = root.appendingPathComponent("BeetCode", isDirectory: true)

        LegacyMigration.migrateFolder(from: legacy, to: new)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("data.json").path))
    }

    func testNoMoveWhenLegacyMissing() throws {
        let legacy = root.appendingPathComponent("LocalForge", isDirectory: true)
        let new = root.appendingPathComponent("BeetCode", isDirectory: true)

        LegacyMigration.migrateFolder(from: legacy, to: new)

        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path),
                       "must not create the new folder when there is nothing to migrate")
    }

    func testNoMoveWhenNewAlreadyExists() throws {
        let legacy = try makeFolder("LocalForge")
        let new = try makeFolder("BeetCode", file: "existing.json")

        LegacyMigration.migrateFolder(from: legacy, to: new)

        // Both folders untouched — never overwrite current data.
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: new.appendingPathComponent("existing.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: new.appendingPathComponent("data.json").path))
    }

    func testMigrationIsIdempotent() throws {
        let legacy = try makeFolder("LocalForge")
        let new = root.appendingPathComponent("BeetCode", isDirectory: true)

        LegacyMigration.migrateFolder(from: legacy, to: new)
        LegacyMigration.migrateFolder(from: legacy, to: new)  // second run: no-op

        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("data.json").path))
    }
}
