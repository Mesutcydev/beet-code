import XCTest
@testable import BeetCode

final class SessionStoreTests: XCTestCase {

    private func isolatedStore() -> (SessionStore, URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-sessions-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let store = SessionStore()
        store.overrideSessionsDir = temp
        return (store, temp)
    }

    func testSaveLoadRoundTrip() throws {
        let (store, temp) = isolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }

        let record = SessionRecord(
            id: UUID(),
            title: "Fix the build",
            createdAt: Date(),
            updatedAt: Date(),
            workspacePath: "/tmp",
            modelID: "qwen",
            messages: [
                SessionMessage(role: .user, content: "hello", toolName: nil, timestamp: Date()),
                SessionMessage(
                    role: .assistant,
                    content: "hi",
                    toolName: nil,
                    timestamp: Date(),
                    answerMetrics: AnswerMetrics(
                        outputTokens: 2,
                        tokensPerSecond: 8.5,
                        elapsedSeconds: 0.4,
                        tokenCountIsEstimated: false)),
                SessionMessage(role: .toolCall, content: "{\"command\": \"swift build\"}", toolName: "run_command", timestamp: Date()),
                SessionMessage(role: .toolResult, content: "Build succeeded", toolName: "run_command", timestamp: Date()),
            ],
            checkpoints: [SessionCheckpoint(id: UUID(), treeSHA: "abc", createdAt: Date(), summary: "before")],
            schemaVersion: nil)

        store.save(record)
        let loaded = store.load(id: record.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.title, record.title)
        XCTAssertEqual(loaded?.messages.count, record.messages.count)
        XCTAssertEqual(loaded?.messages[1].answerMetrics, record.messages[1].answerMetrics)
        XCTAssertEqual(loaded?.checkpoints.count, 1)
        // Schema version is stamped on save.
        XCTAssertEqual(loaded?.schemaVersion, SessionRecord.currentSchemaVersion)
        // loadAll returns it sorted.
        XCTAssertEqual(store.loadAll().map(\.id), [record.id])
        store.delete(record)
        XCTAssertNil(store.load(id: record.id))
    }

    func testProjectFreeChatBindingIsValidWithoutAFolder() {
        let (store, temp) = isolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        let record = SessionRecord(
            id: UUID(),
            title: "Chat only",
            createdAt: Date(),
            updatedAt: Date(),
            workspacePath: "",
            modelID: "m",
            messages: [],
            checkpoints: [])

        XCTAssertTrue(store.validateWorkspaceBinding(record))
    }

    func testSecretsAreRedactedBeforePersistence() {
        let scrubbed = SessionStore.redact(
            "token hf_AbCdEf1234567890AbCdEf1234 and sk-abcdefghijklmnopqrstuvwx and Authorization: Bearer xyz-token-value-1234")
        XCTAssertFalse(scrubbed.contains("hf_AbCdEf1234567890"), scrubbed)
        XCTAssertFalse(scrubbed.contains("sk-abcdefghijklmnopqrstuvwx"), scrubbed)
        XCTAssertFalse(scrubbed.contains("xyz-token-value-1234"), scrubbed)
        XCTAssertTrue(scrubbed.contains("[redacted]"), scrubbed)
    }

    func testToolOutputIsBoundedAndRedacted() {
        let big = String(repeating: "x", count: 30_000)
        let messages = [
            SessionMessage(role: .toolResult, content: "output hf_AbCdEf1234567890AbCdEf1234 " + big, toolName: "run_command", timestamp: Date()),
        ]
        let bounded = SessionStore.redactAndBound(messages)
        XCTAssertLessThan(bounded[0].content.utf8.count, 20_000)
        XCTAssertFalse(bounded[0].content.contains("hf_AbCdEf1234567890"))
        XCTAssertTrue(bounded[0].content.contains("truncated for persistence"))
    }

    func testEncryptedPayloadsAreNotPlaintextJSON() throws {
        let (store, temp) = isolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        let record = SessionRecord(
            id: UUID(),
            title: "secret session",
            createdAt: Date(),
            updatedAt: Date(),
            workspacePath: "/tmp",
            modelID: "m",
            messages: [SessionMessage(role: .user, content: "payload", toolName: nil, timestamp: Date())],
            checkpoints: [],
            schemaVersion: nil)
        store.save(record)
        // The on-disk payload must not be decodable as plain JSON.
        let url = temp.appendingPathComponent("\(record.id.uuidString).session")
        let data = try Data(contentsOf: url)
        XCTAssertNil(try? JSONDecoder().decode(SessionRecord.self, from: data),
                      "sessions must be encrypted at rest")
        XCTAssertNotNil(SessionCrypto.decrypt(data), "payload must use the session cipher")
    }

    func testFailedSaveIsReportedAndCanBeRetried() throws {
        let store = SessionStore()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-session-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let invalidDirectory = temp.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: invalidDirectory)
        store.overrideSessionsDir = invalidDirectory

        let record = SessionRecord(
            id: UUID(),
            title: "retry me",
            createdAt: Date(),
            updatedAt: Date(),
            workspacePath: "/tmp",
            modelID: "m",
            messages: [SessionMessage(
                role: .user, content: "do not lose this", toolName: nil, timestamp: Date())],
            checkpoints: [])

        guard case .failure(let error) = store.save(record) else {
            return XCTFail("a write beneath a regular file must fail")
        }
        if case .writeFailed = error {
            // Expected typed failure.
        } else {
            XCTFail("unexpected save error: \(error)")
        }
        XCTAssertEqual(store.pendingSaveCount, 1)

        let validDirectory = temp.appendingPathComponent("sessions", isDirectory: true)
        store.overrideSessionsDir = validDirectory
        let retry = store.retryPendingSaves()[record.id]
        guard case .success? = retry else {
            return XCTFail("pending save should succeed after storage recovers")
        }
        XCTAssertEqual(store.pendingSaveCount, 0)
        XCTAssertEqual(store.load(id: record.id)?.messages.first?.content, "do not lose this")
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "com.beetcode.tests.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testNewStoreDefaultsToDark() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.appearance, .dark)
        XCTAssertFalse(store.computerControlEnabled)
        XCTAssertFalse(store.intelligenceInspectorEnabled)
    }

    func testLegacyBeetAppearanceMigratesToDarkOnce() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppAppearance.beet.rawValue, forKey: "appearance")

        let migrated = SettingsStore(defaults: defaults)
        XCTAssertEqual(migrated.appearance, .dark)

        migrated.appearance = .beet
        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.appearance, .beet)
    }
}

final class AppPreferencesTests: XCTestCase {

    func testPreferencesRoundTripAndValidation() throws {
        let store = AppPreferencesStore.shared
        let previous = store.current
        defer { store.save(previous) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lf-prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var preferences = AppPreferences()
        preferences.lastWorkspacePath = temp.path
        preferences.lastModelID = "qwen-3-4b"
        preferences.autoResumeDownloads = true
        preferences.hasCompletedWelcome = true

        store.save(preferences)
        let reloaded = store.current
        XCTAssertEqual(reloaded.lastWorkspacePath, temp.path)
        XCTAssertEqual(reloaded.lastModelID, "qwen-3-4b")
        XCTAssertTrue(reloaded.autoResumeDownloads)
        XCTAssertTrue(reloaded.hasCompletedWelcome)

        // Validation: an existing directory validates; a missing one fails
        // without deleting stored state.
        let validated = store.validatedWorkspaceURL()
        XCTAssertEqual(validated?.path, temp.path)
        var broken = preferences
        broken.lastWorkspacePath = temp.appendingPathComponent("gone").path
        store.save(broken)
        XCTAssertNil(store.validatedWorkspaceURL())
        // State is untouched.
        XCTAssertEqual(store.current.lastWorkspacePath, broken.lastWorkspacePath)
    }

    func testWorkspaceTrustIsExplicit() throws {
        let previous = AppPreferencesStore.shared.current
        defer { AppPreferencesStore.shared.save(previous) }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var cleared = previous
        cleared.trustedWorkspacePaths = []
        AppPreferencesStore.shared.save(cleared)
        XCTAssertFalse(WorkspaceTrust.isTrusted(temp))
        XCTAssertFalse(WorkspaceTrust.hasProjectExecutables(temp))
        try FileManager.default.createDirectory(
            at: temp.appendingPathComponent(".beetcode"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: temp.appendingPathComponent(".beetcode/hooks.json"))
        XCTAssertTrue(WorkspaceTrust.hasProjectExecutables(temp))
        XCTAssertTrue(WorkspaceTrust.needsConsent(temp))
        WorkspaceTrust.trust(temp)
        XCTAssertTrue(WorkspaceTrust.isTrusted(temp))
        XCTAssertFalse(WorkspaceTrust.needsConsent(temp))
    }
}
