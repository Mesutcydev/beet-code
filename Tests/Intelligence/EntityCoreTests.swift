import Foundation
import XCTest
@testable import BeetCode

/// Phase 14 — Feature + framework semantics. Tests exercise the real
/// adapter against real parser output, and the store against real SQLite.
final class EntityCoreTests: XCTestCase {

    private var retainedStores: [TempWorkspace] = []

    // MARK: Fixtures

    private let swiftUIFile = """
    import SwiftUI

    struct SettingsView: View {
        @EnvironmentObject private var appState: AppState
        @Environment(\\.dismiss) private var dismiss
        @State private var draft = ""

        var body: some View {
            Text(draft)
        }
    }

    final class AppState: ObservableObject {
        @Published var isReady = false
        @Published var retryCount = 0
    }

    @Observable
    final class DraftModel {
        var text = ""
    }

    @Model
    final class CachedMessage {
        var body = ""
    }

    struct ChatMigration: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [] }
    }
    """

    private let servicesFile = """
    import Foundation

    enum API {
        static let base = "https://api.beetcode.dev"
        static let chat = "https://api.beetcode.dev/v1/chat"
        static let local = "http://localhost:11434/v1"
    }

    func loadKey() -> String? {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }
    """

    private let backgroundFile = """
    import BackgroundTasks

    enum RefreshScheduler {
        static func register() {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: "dev.beetcode.refresh", using: nil) { _ in }
        }
    }
    """

    private let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
        <key>NSCameraUsageDescription</key>
        <string>Scan codes.</string>
        <key>NSMicrophoneUsageDescription</key>
        <string>Voice input.</string>
    </dict>
    </plist>
    """

    private let entitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
        <key>com.apple.security.app-sandbox</key>
        <true/>
        <key>com.apple.security.network.client</key>
        <true/>
    </dict>
    </plist>
    """

    private let projectYML = """
    name: Demo
    targets:
      BeetCode:
        type: application
      BeetCodeTests:
        type: bundle.unit-test
    settings: {}
    """

    // MARK: Adapter

    private func detect(_ content: String, path: String) -> [SemanticEntity] {
        let source = SourceFile(path: path, content: content, contentHash: "h")
        let parsed = ParserRegistry.parse(file: source)
        return SwiftUIFrameworkAdapter().detect(file: source, parsed: parsed)
    }

    func testScreenDetectionWithEnvironmentDependencies() {
        let entities = detect(swiftUIFile, path: "Sources/Settings/SettingsView.swift")
        let screens = entities.filter { $0.kind == .screen }
        XCTAssertEqual(screens.map(\.name), ["SettingsView"])
        let deps = screens[0].attributes["environmentDependencies"] ?? ""
        XCTAssertTrue(deps.contains("appState"))
        XCTAssertTrue(deps.contains("dismiss"))
        XCTAssertNotNil(screens[0].symbolID)
    }

    func testProviderDetectionBothAPIs() {
        let entities = detect(swiftUIFile, path: "Sources/Settings/SettingsView.swift")
        let providers = entities.filter { $0.kind == .provider }.map(\.name).sorted()
        XCTAssertEqual(providers, ["AppState", "DraftModel"])
        let appState = entities.first { $0.name == "AppState" }
        XCTAssertEqual(appState?.attributes["stateModel"], "observableObject")
        XCTAssertEqual(appState?.attributes["publishedProperties"], "isReady,retryCount")
        let draft = entities.first { $0.name == "DraftModel" }
        XCTAssertEqual(draft?.attributes["stateModel"], "observableMacro")
    }

    func testSwiftDataModelAndMigration() {
        let entities = detect(swiftUIFile, path: "Sources/Settings/SettingsView.swift")
        XCTAssertTrue(entities.contains { $0.kind == .databaseModel && $0.name == "CachedMessage" })
        XCTAssertTrue(entities.contains { $0.kind == .migration && $0.name == "ChatMigration" })
    }

    func testServiceEndpointAndSecretDetection() {
        let entities = detect(servicesFile, path: "Sources/Net/API.swift")
        XCTAssertTrue(entities.contains {
            $0.kind == .externalService && $0.name == "api.beetcode.dev" })
        XCTAssertTrue(entities.contains {
            $0.kind == .endpoint && $0.name == "https://api.beetcode.dev/v1/chat" })
        // Base URL has no path → service only, not an endpoint.
        XCTAssertFalse(entities.contains {
            $0.kind == .endpoint && $0.name == "https://api.beetcode.dev" })
        // Local hosts are not external services.
        XCTAssertFalse(entities.contains { $0.name.contains("localhost") })
        XCTAssertTrue(entities.contains {
            $0.kind == .secretReference && $0.name == "OPENAI_API_KEY" })
    }

    func testBackgroundTaskDetection() {
        let entities = detect(backgroundFile, path: "Sources/Refresh/RefreshScheduler.swift")
        XCTAssertTrue(entities.contains {
            $0.kind == .backgroundTask && $0.name == "dev.beetcode.refresh" })
    }

    func testPlistPermissionsAndEntitlements() {
        let permissions = detect(infoPlist, path: "App/Info.plist")
        XCTAssertEqual(permissions.filter { $0.kind == .permission }.map(\.name).sorted(),
                       ["Camera", "Microphone"])
        let ents = detect(entitlements, path: "App/Demo.entitlements")
        XCTAssertEqual(ents.filter { $0.kind == .entitlement }.count, 2)
        XCTAssertTrue(ents.contains { $0.name == "com.apple.security.app-sandbox" })
    }

    func testBuildTargetDetection() {
        let targets = detect(projectYML, path: "project.yml")
        XCTAssertEqual(targets.filter { $0.kind == .buildTarget }.map(\.name).sorted(),
                       ["BeetCode", "BeetCodeTests"])
        let package = detect("""
        import PackageDescription
        let package = Package(
            name: "demo",
            targets: [
                .target(name: "Core"),
                .testTarget(name: "CoreTests", dependencies: ["Core"]),
            ]
        )
        """, path: "Package.swift")
        XCTAssertEqual(package.filter { $0.kind == .buildTarget }.map(\.name), ["Core"])
    }

    // MARK: Store

    private func makeStore() throws -> EntityStore {
        try EntityStore(store: SQLiteStore(url: URL(fileURLWithPath: "/tmp/x"), inMemory: true))
    }

    func testStoreReplaceAndRemove() throws {
        let store = try makeStore()
        let entities = detect(swiftUIFile, path: "Sources/Settings/SettingsView.swift")
        try store.replaceEntities(forFile: "Sources/Settings/SettingsView.swift", entities: entities)
        XCTAssertEqual(try store.count(), entities.count)
        XCTAssertFalse(try store.entities(ofKind: .screen).isEmpty)

        // Re-detect on a "changed" file replaces, never duplicates.
        let reduced = detect("struct Plain {}", path: "Sources/Settings/SettingsView.swift")
        try store.replaceEntities(forFile: "Sources/Settings/SettingsView.swift", entities: reduced)
        XCTAssertEqual(try store.count(), 0)

        let other = detect("struct AV: View { var body: some View { Text(\"\") } }",
                           path: "a.swift")
        try store.replaceEntities(forFile: "a.swift", entities: other)
        XCTAssertEqual(try store.count(), 1)
        try store.removeFile(path: "a.swift")
        XCTAssertEqual(try store.count(), 0)
    }

    func testEntityIdentityIsLineIndependent() {
        let first = detect(swiftUIFile, path: "Sources/Settings/SettingsView.swift")
        let padded = "\n\n\n" + swiftUIFile
        let second = detect(padded, path: "Sources/Settings/SettingsView.swift")
        let firstIDs = Set(first.map(\.id))
        let secondIDs = Set(second.map(\.id))
        XCTAssertEqual(firstIDs, secondIDs) // shifting lines must not change identity
    }

    func testFeatureGrouping() throws {
        let store = try makeStore()
        try store.replaceEntities(
            forFile: "Sources/Auth/LoginView.swift",
            entities: detect("struct LoginView: View { var body: some View { Text(\"\") } }",
                             path: "Sources/Auth/LoginView.swift"))
        try store.replaceEntities(
            forFile: "Sources/Chat/ChatView.swift",
            entities: detect("struct ChatView: View { var body: some View { Text(\"\") } }",
                             path: "Sources/Chat/ChatView.swift"))
        try store.replaceEntities(
            forFile: "Networking/Client.swift",
            entities: detect(servicesFile, path: "Networking/Client.swift"))
        let features = try store.features()
        XCTAssertEqual(features["Auth"]?.first?.name, "LoginView")
        XCTAssertEqual(features["Chat"]?.first?.name, "ChatView")
        XCTAssertFalse(features["Networking"]?.isEmpty ?? true)
        XCTAssertEqual(EntityStore.featureName(forPath: "README.md"), "(root)")
    }

    // MARK: IndexEngine integration

    func testIndexEngineDetectsAndRefreshesEntities() async throws {
        let ws = TempWorkspace()
        retainedStores.append(ws)
        ws.write(swiftUIFile, to: "Sources/Settings/SettingsView.swift")

        let storeDir = TempWorkspace()
        retainedStores.append(storeDir)
        let graph = try SymbolGraph(store: SQLiteStore(
            url: storeDir.url.appendingPathComponent("graph.sqlite")))
        let journal = try InvalidationJournal(store: SQLiteStore(
            url: storeDir.url.appendingPathComponent("metadata.sqlite")))
        let entities = try EntityStore(store: SQLiteStore(
            url: storeDir.url.appendingPathComponent("graph.sqlite")))
        let snapshotStore = WorkspaceSnapshotStore()
        snapshotStore.overrideDirectory = storeDir.url.appendingPathComponent("snapshots")
        let engine = IndexEngine(
            identity: WorkspaceIdentity.resolve(root: ws.url),
            graph: graph, journal: journal,
            snapshotStore: snapshotStore, entityStore: entities)

        try await engine.fullIndex()
        XCTAssertTrue(try entities.entities(ofKind: .screen).contains { $0.name == "SettingsView" })
        XCTAssertTrue(try entities.entities(ofKind: .provider).contains { $0.name == "AppState" })

        // The view loses its conformance → the entity must disappear.
        ws.write("struct SettingsView {}", to: "Sources/Settings/SettingsView.swift")
        let stats = try await engine.incrementalUpdate()
        XCTAssertEqual(stats.modified, 1)
        XCTAssertFalse(try entities.entities(ofKind: .screen).contains { $0.name == "SettingsView" })
    }
}
