import SQLite3
import XCTest
@testable import BeetCode

final class ExternalHistoryImporterTests: XCTestCase {

    // MARK: Claude

    func testClaudeParsesUserAndAssistantTurns() {
        let jsonl = """
        {"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T16:12:34.385Z","sessionId":"s1","content":"hey"}
        {"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"fix the build"},"uuid":"u1","timestamp":"2026-08-14T16:12:34.416Z","cwd":"/tmp/proj","sessionId":"s1"}
        {"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it — running the build now."}]},"uuid":"a1","timestamp":"2026-08-14T16:12:35.000Z","sessionId":"s1"}
        {"parentUuid":"a1","isSidechain":true,"type":"user","message":{"role":"user","content":"sidechain noise"},"uuid":"u2","timestamp":"2026-08-14T16:12:36.000Z","sessionId":"s1"}
        """
        let conversation = ExternalHistoryImporter.parseClaudeJSONL(jsonl)
        XCTAssertEqual(conversation?.source, .claude)
        XCTAssertEqual(conversation?.externalID, "s1")
        XCTAssertEqual(conversation?.workspacePath, "/tmp/proj")
        XCTAssertEqual(conversation?.messages.count, 2)
        XCTAssertEqual(conversation?.messages.first?.role, .user)
        XCTAssertEqual(conversation?.messages.first?.content, "fix the build")
        XCTAssertEqual(conversation?.messages.last?.role, .assistant)
        XCTAssertEqual(conversation?.title, "fix the build")
    }

    func testClaudePreservesToolStructure() {
        let jsonl = """
        {"isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"swift build"}}]},"uuid":"a1","timestamp":"2026-08-14T16:12:35.000Z","sessionId":"s3"}
        {"isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"Build complete."}]},"uuid":"u1","timestamp":"2026-08-14T16:12:36.000Z","sessionId":"s3"}
        """
        let conversation = ExternalHistoryImporter.parseClaudeJSONL(jsonl)
        XCTAssertEqual(conversation?.messages.count, 3)
        XCTAssertEqual(conversation?.messages[0].role, .assistant)
        XCTAssertEqual(conversation?.messages[1].role, .toolCall)
        XCTAssertEqual(conversation?.messages[1].toolName, "Bash")
        XCTAssertEqual(conversation?.messages[1].content, #"{"command":"swift build"}"#)
        XCTAssertEqual(conversation?.messages[2].role, .toolResult)
        XCTAssertEqual(conversation?.messages[2].toolName, "Bash")
        XCTAssertEqual(conversation?.messages[2].content, "Build complete.")
    }

    func testClaudeSkipsNonTextBlocks() {
        let jsonl = """
        {"isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"rm -rf /"},{"type":"text","text":"real question"}]},"uuid":"u1","timestamp":"2026-08-14T16:12:34.416Z","cwd":"/tmp","sessionId":"s2"}
        """
        let conversation = ExternalHistoryImporter.parseClaudeJSONL(jsonl)
        XCTAssertEqual(conversation?.messages.count, 2)
        XCTAssertEqual(conversation?.messages.first?.role, .toolResult)
        XCTAssertEqual(conversation?.messages.last?.content, "real question")
    }

    func testClaudeEmptyWhenNoTurns() {
        XCTAssertNil(ExternalHistoryImporter.parseClaudeJSONL("{\"type\":\"summary\"}\n"))
    }

    // MARK: Codex

    func testCodexParsesRolloutAndDropsContextInjections() {
        let jsonl = """
        {"timestamp":"2026-07-04T08:55:13.009Z","type":"session_meta","payload":{"session_id":"codex-1","cwd":"/tmp/site"}}
        {"timestamp":"2026-07-04T08:55:14.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>stuff</environment_context>"}]}}
        {"timestamp":"2026-07-04T08:55:15.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"bump the version to 1.7"}]}}
        {"timestamp":"2026-07-04T08:55:16.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Version bumped and build uploaded."}]}}
        {"timestamp":"2026-07-04T08:55:17.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{\\\"cmd\\\": \\\"swift build\\\"}"}}
        {"timestamp":"2026-07-04T08:55:18.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Build succeeded"}}
        """
        let conversation = ExternalHistoryImporter.parseCodexJSONL(jsonl, fallbackID: "rollout-x")
        XCTAssertEqual(conversation?.source, .codex)
        XCTAssertEqual(conversation?.externalID, "codex-1")
        XCTAssertEqual(conversation?.workspacePath, "/tmp/site")
        XCTAssertEqual(conversation?.messages.count, 4)
        XCTAssertEqual(conversation?.messages[0].content, "bump the version to 1.7")
        XCTAssertEqual(conversation?.messages[1].role, .assistant)
        XCTAssertEqual(conversation?.messages[2].role, .toolCall)
        XCTAssertEqual(conversation?.messages[2].toolName, "shell")
        XCTAssertEqual(conversation?.messages[3].role, .toolResult)
        XCTAssertEqual(conversation?.messages[3].toolName, "shell")
        XCTAssertEqual(conversation?.messages[3].content, "Build succeeded")
    }

    func testCodexEmptyWhenOnlyContext() {
        let jsonl = """
        {"timestamp":"2026-07-04T08:55:13.009Z","type":"session_meta","payload":{"session_id":"c2","cwd":"/tmp"}}
        {"timestamp":"2026-07-04T08:55:14.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>only</environment_context>"}]}}
        """
        XCTAssertNil(ExternalHistoryImporter.parseCodexJSONL(jsonl, fallbackID: "x"))
    }

    // MARK: Cursor

    func testCursorReadsPromptsAndBubbles() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let manifest = temp.appendingPathComponent("workspace.json")
        try #"{"folder":"file:///tmp/proj"}"#.write(to: manifest, atomically: true, encoding: .utf8)

        let dbURL = temp.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, #"INSERT INTO ItemTable VALUES ('aiService.prompts', '[{"text":"make a repo","commandType":4}]')"#, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, #"INSERT INTO cursorDiskKV VALUES ('bubbleId:c1:b1', '{"text":"Repo created."}')"#, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db); db = nil

        let conversation = ExternalHistoryImporter.parseCursorWorkspace(database: dbURL, manifest: manifest)
        XCTAssertEqual(conversation?.source, .cursor)
        XCTAssertEqual(conversation?.workspacePath, "/tmp/proj")
        XCTAssertEqual(conversation?.messages.count, 2)
        XCTAssertEqual(conversation?.messages.first?.role, .user)
        XCTAssertEqual(conversation?.messages.last?.role, .assistant)
        XCTAssertEqual(conversation?.title, "make a repo")
    }

    // MARK: Deterministic identity

    func testDeterministicUUIDIsStableAndDistinct() {
        let a1 = ExternalHistoryImporter.deterministicUUID("beetcode-import:claude:s1")
        let a2 = ExternalHistoryImporter.deterministicUUID("beetcode-import:claude:s1")
        let b = ExternalHistoryImporter.deterministicUUID("beetcode-import:codex:s1")
        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, b)
    }

    // MARK: End-to-end import

    func testImportAllIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-home-\(UUID().uuidString)")
        let claudeDir = home.appendingPathComponent(".claude/projects/-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let jsonl = """
        {"isSidechain":false,"type":"user","message":{"role":"user","content":"hello claude"},"uuid":"u1","timestamp":"2026-08-14T16:12:34.416Z","cwd":"/tmp","sessionId":"s9"}
        """
        try jsonl.write(to: claudeDir.appendingPathComponent("s9.jsonl"), atomically: true, encoding: .utf8)

        let store = SessionStore()
        let storeDir = home.appendingPathComponent("sessions", isDirectory: true)
        store.overrideSessionsDir = storeDir

        let first = ExternalHistoryImporter.importAll(home: home, into: store)
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(first.perSource[.claude], 1)

        let second = ExternalHistoryImporter.importAll(home: home, into: store)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.upToDate, 1)

        let records = store.loadAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.source, .claude)
        XCTAssertEqual(records.first?.title, "hello claude")
    }

    // MARK: Backward compatibility

    func testLegacyRecordWithoutSourceDecodesAsApp() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"old","createdAt":0,"updatedAt":0,
         "workspacePath":"/tmp","modelID":"q","messages":[],"checkpoints":[]}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(SessionRecord.self, from: json)
        XCTAssertEqual(record.source, .app)
    }

    // MARK: Bounded reading (giant rollout files)

    private func makeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testBoundedReadKeepsSmallFilesByteIdentical() throws {
        let text = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"
        let file = try makeTempFile(contents: text)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(ExternalHistoryImporter.readBoundedText(file),
                       "{\"a\":1}\n{\"b\":2}\n{\"c\":3}")
    }

    func testBoundedReadDropsOversizedLines() throws {
        let fat = String(repeating: "x", count: ExternalHistoryImporter.maxLineBytes + 1)
        let file = try makeTempFile(contents: "{\"ok\":1}\n\(fat)\n{\"after\":2}\n")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(ExternalHistoryImporter.readBoundedText(file),
                       "{\"ok\":1}\n{\"after\":2}")
    }

    func testBoundedReadStopsAtByteBudget() throws {
        // More 1 KB lines than the byte budget admits: the read stops early,
        // and every surviving line is complete (never cut mid-line).
        let line = String(repeating: "y", count: 1024)
        let lineCount = ExternalHistoryImporter.maxBytesPerFile / 1024 + 100
        let text = (0..<lineCount).map { _ in line }.joined(separator: "\n")
        let file = try makeTempFile(contents: text)
        defer { try? FileManager.default.removeItem(at: file) }
        let read = ExternalHistoryImporter.readBoundedText(file)
        XCTAssertNotNil(read)
        XCTAssertLessThan(read!.count, text.count)
        // Never mid-line: every surviving line is the full 1024-char line.
        XCTAssertTrue(read!.split(separator: "\n").allSatisfy { $0.count == 1024 })
    }

    func testBoundedReadParsesGiantCodexRollout() throws {
        // A rollout whose middle is a multi-MB tool dump: the user turn and
        // the function call survive, the dump line is dropped.
        let dump = String(repeating: "z", count: ExternalHistoryImporter.maxLineBytes * 2)
        let jsonl = """
        {"timestamp":"2026-08-09T12:07:28.000Z","type":"session_meta","payload":{"session_id":"big-1","cwd":"/tmp"}}
        {"timestamp":"2026-08-09T12:07:29.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"run the migration"}]}}
        {"timestamp":"2026-08-09T12:07:30.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{}"}}
        \(dump)
        {"timestamp":"2026-08-09T12:07:31.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"done"}}
        """
        let file = try makeTempFile(contents: jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let text = ExternalHistoryImporter.readBoundedText(file)
        XCTAssertNotNil(text)
        let conversation = ExternalHistoryImporter.parseCodexJSONL(text!, fallbackID: "big-1")
        XCTAssertEqual(conversation?.externalID, "big-1")
        XCTAssertEqual(conversation?.messages.map(\.role), [.user, .toolCall, .toolResult])
    }

    // MARK: Live progress

    func testImportAllReportsProgress() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-progress-\(UUID().uuidString)")
        let claudeDir = home.appendingPathComponent(".claude/projects/-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let jsonl = """
        {"isSidechain":false,"type":"user","message":{"role":"user","content":"progress check"},"uuid":"u1","timestamp":"2026-08-14T16:12:34.416Z","cwd":"/tmp","sessionId":"sp"}
        """
        try jsonl.write(to: claudeDir.appendingPathComponent("sp.jsonl"), atomically: true, encoding: .utf8)

        let store = SessionStore()
        store.overrideSessionsDir = home.appendingPathComponent("sessions", isDirectory: true)

        let box = ProgressBox()
        let report = ExternalHistoryImporter.importAll(home: home, into: store) { box.append($0) }

        XCTAssertEqual(report.imported, 1)
        // Phases arrive in order: scan → parse → save.
        let events = box.events
        XCTAssertEqual(events.first?.phase, .scanning)
        XCTAssertTrue(events.contains { $0.phase == .parsing && $0.source == .claude && $0.total == 1 })
        XCTAssertTrue(events.contains { $0.phase == .saving && $0.total == 1 })
        XCTAssertEqual(events.last?.phase, .saving)
    }
}

/// Thread-safe collector for the importer's @Sendable progress callback.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [ImportProgress] = []
    func append(_ event: ImportProgress) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
