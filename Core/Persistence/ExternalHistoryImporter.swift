import CryptoKit
import Foundation
import SQLite3

/// One external chat conversation, normalized from a foreign tool's storage
/// format into something that maps 1:1 onto `SessionRecord`.
struct ImportedConversation: Sendable, Equatable {
    var externalID: String
    var source: SessionSource
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var workspacePath: String
    var messages: [SessionMessage]
}

struct ImportReport: Sendable, Equatable {
    /// Records written (new or updated with fresher content).
    var imported = 0
    /// Conversations already imported at the same or newer state.
    var upToDate = 0
    /// Files/workspaces that yielded no importable conversation.
    var skipped = 0
    /// Per-source counts of written records, for the UI summary.
    var perSource: [SessionSource: Int] = [:]
}

/// Imports chat history from other coding agents — Claude Code
/// (`~/.claude/projects/**/*.jsonl`), Codex (`~/.codex/sessions/**`) and
/// Cursor (`…/Cursor/User/workspaceStorage/*/state.vscdb`) — and saves them
/// as ordinary BeetCode sessions, so the sidebar can browse and restore
/// them through the exact same pipeline as native sessions.
///
/// Imports are idempotent: every conversation gets a deterministic UUID
/// derived from its source + external id, and a record whose stored
/// `updatedAt` is at least as fresh as the source is left untouched.
enum ExternalHistoryImporter {

    /// Safety caps so a giant history folder can't stall the import.
    static let maxFilesPerSource = 50
    static let maxMessagesPerConversation = 500

    // MARK: - Coordinator

    @discardableResult
    static func importAll(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        into store: SessionStore = .shared
    ) -> ImportReport {
        var report = ImportReport()
        for conversation in discoverConversations(home: home) {
            let id = deterministicUUID("beetcode-import:\(conversation.source.rawValue):\(conversation.externalID)")
            if let existing = store.load(id: id), existing.updatedAt >= conversation.updatedAt {
                report.upToDate += 1
                continue
            }
            let record = SessionRecord(
                id: id,
                title: conversation.title,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                workspacePath: conversation.workspacePath,
                modelID: "imported",
                messages: conversation.messages,
                checkpoints: [],
                source: conversation.source)
            store.save(record)
            report.imported += 1
            report.perSource[conversation.source, default: 0] += 1
        }
        return report
    }

    /// Finds every importable conversation under the three tools' stores,
    /// newest files first, capped per source.
    static func discoverConversations(home: URL) -> [ImportedConversation] {
        var conversations: [ImportedConversation] = []

        let claudeRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        for file in recentFiles(under: claudeRoot, suffix: ".jsonl") {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let conversation = parseClaudeJSONL(text) else { continue }
            conversations.append(conversation)
        }

        let codexRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        for file in recentFiles(under: codexRoot, suffix: ".jsonl") {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let conversation = parseCodexJSONL(text, fallbackID: file.deletingPathExtension().lastPathComponent) else { continue }
            conversations.append(conversation)
        }

        let cursorRoot = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/workspaceStorage", isDirectory: true)
        for workspace in directories(under: cursorRoot) {
            let db = workspace.appendingPathComponent("state.vscdb")
            let manifest = workspace.appendingPathComponent("workspace.json")
            guard FileManager.default.fileExists(atPath: db.path),
                  let conversation = parseCursorWorkspace(database: db, manifest: manifest) else { continue }
            conversations.append(conversation)
        }

        return conversations
    }

    /// Newest-modified files with the given suffix under root (recursive),
    /// capped so huge history folders stay cheap.
    private static func recentFiles(under root: URL, suffix: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, modified))
        }
        return files
            .sorted { $0.1 > $1.1 }
            .prefix(maxFilesPerSource)
            .map(\.0)
    }

    private static func directories(under root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            } ?? []
    }

    /// A stable UUID from a namespace string (SHA-256, first 16 bytes), so
    /// re-imports overwrite the same record instead of duplicating it.
    static func deterministicUUID(_ namespace: String) -> UUID {
        let digest = SHA256.hash(data: Data(namespace.utf8))
        let b = Array(digest.prefix(16))
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // MARK: - Claude Code

    /// Claude Code session JSONL: one event per line. User/assistant turns
    /// carry `message.content` as a string or an array of typed blocks;
    /// sidechains, queue operations and attachments are dropped.
    static func parseClaudeJSONL(_ text: String) -> ImportedConversation? {
        var messages: [SessionMessage] = []
        var sessionID: String?
        var workspace = ""
        var first: Date?
        var last: Date?

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String,
                  type == "user" || type == "assistant",
                  event["isSidechain"] as? Bool != true
            else { continue }

            if sessionID == nil { sessionID = event["sessionId"] as? String }
            if workspace.isEmpty, let cwd = event["cwd"] as? String { workspace = cwd }
            let timestamp = parseISO8601(event["timestamp"] as? String)
            if let timestamp {
                if first == nil { first = timestamp }
                last = timestamp
            }

            let role: SessionMessage.Role = type == "user" ? .user : .assistant
            guard let message = event["message"] as? [String: Any],
                  let content = textContent(of: message["content"]),
                  !content.isEmpty
            else { continue }
            messages.append(SessionMessage(
                role: role, content: content, toolName: nil,
                timestamp: timestamp ?? Date()))
        }

        guard !messages.isEmpty else { return nil }
        return ImportedConversation(
            externalID: sessionID ?? deterministicUUID(text).uuidString,
            source: .claude,
            title: makeTitle(from: messages),
            createdAt: first ?? Date(),
            updatedAt: last ?? first ?? Date(),
            workspacePath: workspace.isEmpty ? NSHomeDirectory() : workspace,
            messages: Array(messages.prefix(maxMessagesPerConversation)))
    }

    // MARK: - Codex

    /// Codex rollout JSONL: a `session_meta` header, then `response_item`
    /// events whose payloads are Responses-API items. Only real user /
    /// assistant message items are kept; environment-context and
    /// instructions injections are dropped.
    static func parseCodexJSONL(_ text: String, fallbackID: String) -> ImportedConversation? {
        var messages: [SessionMessage] = []
        var sessionID = fallbackID
        var workspace = ""
        var created: Date?

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            let timestamp = parseISO8601(event["timestamp"] as? String)

            if type == "session_meta", let payload = event["payload"] as? [String: Any] {
                if let id = payload["session_id"] as? String { sessionID = id }
                if let cwd = payload["cwd"] as? String { workspace = cwd }
                if created == nil { created = timestamp }
                continue
            }

            guard type == "response_item",
                  let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String,
                  role == "user" || role == "assistant"
            else { continue }

            guard let content = textContent(of: payload["content"]),
                  !content.isEmpty
            else { continue }
            messages.append(SessionMessage(
                role: role == "user" ? .user : .assistant,
                content: content, toolName: nil,
                timestamp: timestamp ?? Date()))
        }

        guard !messages.isEmpty else { return nil }
        return ImportedConversation(
            externalID: sessionID,
            source: .codex,
            title: makeTitle(from: messages),
            createdAt: created ?? messages.first?.timestamp ?? Date(),
            updatedAt: messages.last?.timestamp ?? Date(),
            workspacePath: workspace.isEmpty ? NSHomeDirectory() : workspace,
            messages: Array(messages.prefix(maxMessagesPerConversation)))
    }

    // MARK: - Cursor

    /// Cursor keeps per-workspace chat state in a SQLite `state.vscdb`:
    /// user prompts in `ItemTable["aiService.prompts"]`, assistant bubbles
    /// in `cursorDiskKV` under `bubbleId:` keys (newer versions may store
    /// nothing locally — then only the prompts are recoverable). There are
    /// no timestamps, so the database file's mtime stands in.
    static func parseCursorWorkspace(database dbURL: URL, manifest: URL) -> ImportedConversation? {
        guard let manifestData = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let folder = (json["folder"] as? String).flatMap({ URL(string: $0)?.path })
        else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        var messages: [SessionMessage] = []
        let modified = (try? dbURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        if let raw = queryItemTable(db, key: "aiService.prompts"),
           let data = raw.data(using: .utf8),
           let prompts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for prompt in prompts {
                guard let text = (prompt["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                messages.append(SessionMessage(role: .user, content: text, toolName: nil, timestamp: modified))
            }
        }

        for bubbleText in queryBubbleTexts(db) {
            messages.append(SessionMessage(role: .assistant, content: bubbleText, toolName: nil, timestamp: modified))
        }

        guard !messages.isEmpty else { return nil }
        return ImportedConversation(
            externalID: dbURL.deletingLastPathComponent().lastPathComponent,
            source: .cursor,
            title: makeTitle(from: messages),
            createdAt: modified,
            updatedAt: modified,
            workspacePath: folder,
            messages: Array(messages.prefix(maxMessagesPerConversation)))
    }

    private static func queryItemTable(_ db: OpaquePointer?, key: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: raw)
    }

    private static func queryBubbleTexts(_ db: OpaquePointer?) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'", -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var texts: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let data = String(cString: raw).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = (value["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { continue }
            texts.append(text)
        }
        return texts
    }

    // MARK: - Shared extraction

    /// Message content arrives either as a plain string or as an array of
    /// typed blocks (`text` / `input_text` / `output_text`). Environment
    /// and instruction injections are context, not prose — dropped.
    private static func textContent(of content: Any?) -> String? {
        if let string = content as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        var parts: [String] = []
        for block in blocks {
            guard let type = block["type"] as? String,
                  ["text", "input_text", "output_text"].contains(type),
                  let text = block["text"] as? String
            else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<environment_context>")
                || trimmed.hasPrefix("<user_instructions>")
                || trimmed.hasPrefix("<system-reminder>") { continue }
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// First user line, single-spaced and capped — the same shape native
    /// session titles have.
    private static func makeTitle(from messages: [SessionMessage]) -> String {
        let basis = messages.first(where: { $0.role == .user })?.content
            ?? messages.first?.content
            ?? "Imported chat"
        let oneLine = basis
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "Imported chat"
        return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
    }

    private static func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
