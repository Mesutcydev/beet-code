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
    /// Records that were parsed but could not be durably encrypted/written.
    var failed = 0
    var lastSaveError: String?
    /// Per-source counts of written records, for the UI summary.
    var perSource: [SessionSource: Int] = [:]
}

/// One live status update during an import, for the progress UI. Fired from
/// whatever thread the import runs on — the UI hops to main itself.
struct ImportProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case scanning  // enumerating a source's files/workspaces
        case parsing   // reading one history file or workspace database
        case saving    // writing imported sessions to the store
    }
    var source: SessionSource
    var phase: Phase
    /// Current item (file or workspace name) — the UI middle-truncates it.
    var detail: String = ""
    var completed: Int = 0
    var total: Int = 0
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
    /// Cursor's current global database indexes individual conversations,
    /// so it can be traversed cheaply without scanning the multi-gigabyte
    /// key/value table. Keep a generous ceiling while bounding launch work.
    static let maxCursorConversations = 500
    static let maxMessagesPerConversation = 500
    /// Per-file read budget. Codex rollouts grow past 3 GB (every tool
    /// output is logged) — reading one whole with String(contentsOf:)
    /// stalled the import for minutes and looked like a hang. Files are
    /// streamed line by line up to this budget instead.
    static let maxBytesPerFile = 16 * 1024 * 1024
    /// A single line longer than this is a fat tool dump, not chat — dropped
    /// before parsing (it would never fit a message bubble anyway).
    static let maxLineBytes = 512 * 1024

    /// Live status sink; called from whatever thread the import runs on.
    typealias ProgressHandler = @Sendable (ImportProgress) -> Void

    // MARK: - Coordinator

    @discardableResult
    static func importAll(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        into store: SessionStore = .shared,
        progress: ProgressHandler? = nil
    ) -> ImportReport {
        var report = ImportReport()
        let conversations = discoverConversations(home: home, progress: progress)
        for (index, conversation) in conversations.enumerated() {
            progress?(ImportProgress(
                source: conversation.source, phase: .saving,
                detail: conversation.title,
                completed: index, total: conversations.count))
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
            if case .failure(let error) = store.save(record) {
                report.failed += 1
                report.lastSaveError = error.localizedDescription
                continue
            }
            report.imported += 1
            report.perSource[conversation.source, default: 0] += 1
        }
        return report
    }

    /// Finds every importable conversation under the three tools' stores,
    /// newest files first, capped per source. Each source announces its scan
    /// and per-file progress through `progress`.
    static func discoverConversations(home: URL, progress: ProgressHandler? = nil) -> [ImportedConversation] {
        var conversations: [ImportedConversation] = []

        let claudeRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        progress?(ImportProgress(source: .claude, phase: .scanning))
        let claudeFiles = recentFiles(under: claudeRoot, suffix: ".jsonl")
        for (index, file) in claudeFiles.enumerated() {
            progress?(ImportProgress(
                source: .claude, phase: .parsing, detail: file.lastPathComponent,
                completed: index, total: claudeFiles.count))
            guard let text = readBoundedText(file),
                  let conversation = parseClaudeJSONL(text) else { continue }
            conversations.append(conversation)
        }

        let codexRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        progress?(ImportProgress(source: .codex, phase: .scanning))
        let codexFiles = recentFiles(under: codexRoot, suffix: ".jsonl")
        for (index, file) in codexFiles.enumerated() {
            progress?(ImportProgress(
                source: .codex, phase: .parsing, detail: file.lastPathComponent,
                completed: index, total: codexFiles.count))
            guard let text = readBoundedText(file),
                  let conversation = parseCodexJSONL(text, fallbackID: file.deletingPathExtension().lastPathComponent) else { continue }
            conversations.append(conversation)
        }

        let cursorUserRoot = home.appendingPathComponent(
            "Library/Application Support/Cursor/User", isDirectory: true)
        let cursorRoot = cursorUserRoot.appendingPathComponent(
            "workspaceStorage", isDirectory: true)
        let cursorGlobal = cursorUserRoot.appendingPathComponent(
            "globalStorage/state.vscdb")
        progress?(ImportProgress(source: .cursor, phase: .scanning))

        // Cursor 1.x keeps one record per conversation in the global store.
        // Prefer it when available: the older workspace tables collapse all
        // chats for a project into one stream and would duplicate them.
        let globalConversations = parseCursorGlobal(
            database: cursorGlobal,
            workspaceStorage: cursorRoot)
        if !globalConversations.isEmpty {
            for (index, conversation) in globalConversations.enumerated() {
                progress?(ImportProgress(
                    source: .cursor, phase: .parsing, detail: conversation.title,
                    completed: index, total: globalConversations.count))
                conversations.append(conversation)
            }
            return conversations
        }

        // Legacy Cursor fallback: workspace-local prompts and bubbles.
        let legacyCursorRoot = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/workspaceStorage", isDirectory: true)
        let cursorWorkspaces = directories(under: legacyCursorRoot)
        for (index, workspace) in cursorWorkspaces.enumerated() {
            progress?(ImportProgress(
                source: .cursor, phase: .parsing, detail: workspace.lastPathComponent,
                completed: index, total: cursorWorkspaces.count))
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

    /// Streams a history file line by line with hard budgets: at most
    /// `maxBytesPerFile` total, and individual lines over `maxLineBytes`
    /// dropped whole (a single Codex tool output can be hundreds of MB).
    /// The result may end mid-conversation but never mid-line, so every
    /// surviving line still parses as complete JSON. Small files come
    /// through byte-identical to String(contentsOf:).
    static func readBoundedText(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var lines: [String] = []
        var consumed = 0
        var carry = Data()  // bytes after the last newline seen so far
        let chunkSize = 256 * 1024
        while consumed < maxBytesPerFile {
            let budget = min(chunkSize, maxBytesPerFile - consumed)
            guard let chunk = try? handle.read(upToCount: budget), !chunk.isEmpty else { break }
            consumed += chunk.count
            carry.append(chunk)
            var lineStart = carry.startIndex
            while let newline = carry[lineStart...].firstIndex(of: 0x0A) {
                let lineData = carry[lineStart..<newline]
                if lineData.count <= maxLineBytes,
                   let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
                lineStart = carry.index(after: newline)
            }
            if lineStart > carry.startIndex {
                carry = Data(carry[lineStart...])
            }
            // An unterminated line already past the cap can only grow —
            // drop it instead of buffering it to the byte budget.
            if carry.count > maxLineBytes { carry.removeAll(keepingCapacity: false) }
        }
        // Tail without a trailing newline: keep only at a true EOF.
        if consumed < maxBytesPerFile, !carry.isEmpty, carry.count <= maxLineBytes,
           let tail = String(data: carry, encoding: .utf8) {
            lines.append(tail)
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
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
    /// sidechains, queue operations and attachments are dropped. `tool_use`
    /// and `tool_result` blocks become real toolCall/toolResult messages
    /// (matched by `tool_use_id`), so imported sessions group into the same
    /// steps cards as native runs.
    static func parseClaudeJSONL(_ text: String) -> ImportedConversation? {
        var messages: [SessionMessage] = []
        var toolNames: [String: String] = [:]  // tool_use_id → tool name
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
            guard let message = event["message"] as? [String: Any] else { continue }

            if let string = message["content"] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    messages.append(SessionMessage(
                        role: role, content: trimmed, toolName: nil,
                        timestamp: timestamp ?? Date()))
                }
                continue
            }

            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            var textParts: [String] = []
            func flushText() {
                guard !textParts.isEmpty else { return }
                messages.append(SessionMessage(
                    role: role, content: textParts.joined(separator: "\n\n"),
                    toolName: nil, timestamp: timestamp ?? Date()))
                textParts = []
            }

            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = (block["text"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty, !isInjectedContext(text) {
                        textParts.append(text)
                    }
                case "tool_use":
                    flushText()
                    let name = block["name"] as? String ?? "tool"
                    if let id = block["id"] as? String { toolNames[id] = name }
                    messages.append(SessionMessage(
                        role: .toolCall,
                        content: jsonString(of: block["input"]) ?? "{}",
                        toolName: name, timestamp: timestamp ?? Date()))
                case "tool_result":
                    flushText()
                    let output = resultText(of: block["content"])
                    guard !output.isEmpty else { continue }
                    let name = (block["tool_use_id"] as? String).flatMap { toolNames[$0] }
                    messages.append(SessionMessage(
                        role: .toolResult, content: output,
                        toolName: name, timestamp: timestamp ?? Date()))
                default:
                    continue
                }
            }
            flushText()
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
    /// events whose payloads are Responses-API items. User/assistant
    /// messages are kept (context injections dropped); `function_call` and
    /// `function_call_output` become real toolCall/toolResult messages
    /// (matched by `call_id`), so imported runs group into steps cards like
    /// native ones.
    static func parseCodexJSONL(_ text: String, fallbackID: String) -> ImportedConversation? {
        var messages: [SessionMessage] = []
        var callNames: [String: String] = [:]  // call_id → tool name
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
                  let payloadType = payload["type"] as? String
            else { continue }

            switch payloadType {
            case "message":
                guard let role = payload["role"] as? String,
                      role == "user" || role == "assistant",
                      let content = textContent(of: payload["content"]),
                      !content.isEmpty
                else { continue }
                messages.append(SessionMessage(
                    role: role == "user" ? .user : .assistant,
                    content: content, toolName: nil,
                    timestamp: timestamp ?? Date()))
            case "function_call":
                let name = payload["name"] as? String ?? "tool"
                if let callID = payload["call_id"] as? String { callNames[callID] = name }
                messages.append(SessionMessage(
                    role: .toolCall,
                    content: payload["arguments"] as? String ?? "{}",
                    toolName: name, timestamp: timestamp ?? Date()))
            case "function_call_output":
                let output = resultText(of: payload["output"])
                guard !output.isEmpty else { continue }
                let name = (payload["call_id"] as? String).flatMap { callNames[$0] }
                messages.append(SessionMessage(
                    role: .toolResult, content: output,
                    toolName: name, timestamp: timestamp ?? Date()))
            default:
                continue
            }
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

    private struct CursorComposerHeader {
        let id: String
        let workspaceID: String
        let title: String?
        let createdAt: Date
        let updatedAt: Date
    }

    /// Current Cursor keeps conversation headers in the global database and
    /// the ordered bubble ids in `cursorDiskKV[composerData:<id>]`. Each
    /// bubble lives at `bubbleId:<composer>:<bubble>`. Exact-key reads use
    /// Cursor's unique index, so the importer never scans the enormous KV
    /// table and remains responsive even when it is several gigabytes.
    static func parseCursorGlobal(database dbURL: URL, workspaceStorage: URL) -> [ImportedConversation] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)

        let headers = queryCursorComposerHeaders(db)
        guard !headers.isEmpty else { return [] }
        var conversations: [ImportedConversation] = []
        for header in headers {
            guard let rawComposer = queryCursorDiskValue(db, key: "composerData:\(header.id)"),
                  let data = rawComposer.data(using: .utf8),
                  let composer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bubbleHeaders = composer["fullConversationHeadersOnly"] as? [[String: Any]]
            else { continue }

            var messages: [SessionMessage] = []
            for bubbleHeader in bubbleHeaders {
                guard let bubbleID = bubbleHeader["bubbleId"] as? String,
                      let rawBubble = queryCursorDiskValue(
                        db, key: "bubbleId:\(header.id):\(bubbleID)"),
                      let bubbleData = rawBubble.data(using: .utf8),
                      let bubble = try? JSONSerialization.jsonObject(with: bubbleData) as? [String: Any]
                else { continue }

                let type = (bubble["type"] as? NSNumber)?.intValue
                    ?? (bubbleHeader["type"] as? NSNumber)?.intValue
                guard type == 1 || type == 2,
                      let text = cursorBubbleText(bubble),
                      !isInjectedContext(text)
                else { continue }
                let timestamp = parseISO8601(bubble["createdAt"] as? String)
                    ?? header.updatedAt
                messages.append(SessionMessage(
                    role: type == 1 ? .user : .assistant,
                    content: text,
                    toolName: nil,
                    timestamp: timestamp))
                if messages.count >= maxMessagesPerConversation { break }
            }

            guard !messages.isEmpty else { continue }
            let workspace = cursorWorkspacePath(
                workspaceID: header.workspaceID,
                workspaceStorage: workspaceStorage)
            conversations.append(ImportedConversation(
                externalID: header.id,
                source: .cursor,
                title: header.title ?? makeTitle(from: messages),
                createdAt: header.createdAt,
                updatedAt: header.updatedAt,
                workspacePath: workspace,
                messages: messages))
        }
        return conversations
    }

    /// Older Cursor versions keep per-workspace chat state in SQLite:
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

    private static func queryCursorComposerHeaders(_ db: OpaquePointer?) -> [CursorComposerHeader] {
        var statement: OpaquePointer?
        let sql = """
        SELECT composerId, workspaceId, createdAt, lastUpdatedAt, value
        FROM composerHeaders
        WHERE COALESCE(isSubagent, 0) = 0
        ORDER BY lastUpdatedAt DESC
        LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(maxCursorConversations))

        var headers: [CursorComposerHeader] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let workspaceID = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let createdMilliseconds = sqlite3_column_int64(statement, 2)
            let updatedMilliseconds = sqlite3_column_int64(statement, 3)
            let metadata = sqlite3_column_text(statement, 4)
                .flatMap { String(cString: $0).data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let rawTitle = (metadata?["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers.append(CursorComposerHeader(
                id: id,
                workspaceID: workspaceID,
                title: rawTitle?.isEmpty == false ? rawTitle : nil,
                createdAt: cursorDate(milliseconds: createdMilliseconds),
                updatedAt: cursorDate(milliseconds: updatedMilliseconds)))
        }
        return headers
    }

    private static func queryCursorDiskValue(_ db: OpaquePointer?, key: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM cursorDiskKV WHERE key = ?", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: raw)
    }

    private static func cursorBubbleText(_ bubble: [String: Any]) -> String? {
        for key in ["text", "content"] {
            if let text = (bubble[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func cursorWorkspacePath(workspaceID: String, workspaceStorage: URL) -> String {
        guard !workspaceID.isEmpty, workspaceID != "empty-window" else { return NSHomeDirectory() }
        let manifest = workspaceStorage
            .appendingPathComponent(workspaceID, isDirectory: true)
            .appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return NSHomeDirectory() }
        for key in ["folder", "workspace"] {
            guard let raw = json[key] as? String else { continue }
            if let url = URL(string: raw), url.isFileURL {
                return url.path
            }
            if raw.hasPrefix("/") { return raw }
        }
        return NSHomeDirectory()
    }

    private static func cursorDate(milliseconds: Int64) -> Date {
        guard milliseconds > 0 else { return Date() }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
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
            if isInjectedContext(trimmed) { continue }
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Context wrappers the source tools inject around real prose.
    private static func isInjectedContext(_ text: String) -> Bool {
        text.hasPrefix("<environment_context>")
            || text.hasPrefix("<user_instructions>")
            || text.hasPrefix("<system-reminder>")
            || text.hasPrefix("<system_reminder>")
            || text.hasPrefix("<recommended_plugins>")
            || text.hasPrefix("<permissions")
            || SessionTitle.isNoise(text)
    }

    /// Tool results are a plain string, an array of text blocks, or (Codex)
    /// an object wrapping the payload — all flatten to one string.
    private static func resultText(of content: Any?) -> String {
        if let string = content as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let blocks = content as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                guard let text = block["text"] as? String else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return parts.joined(separator: "\n")
        }
        if let object = content as? [String: Any] {
            for key in ["output", "content", "text"] {
                if let nested = object[key] { return resultText(of: nested) }
            }
        }
        return ""
    }

    /// Serialize a decoded JSON value back to a string (tool_call inputs).
    private static func jsonString(of value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// First user line, single-spaced and capped — the same shape native
    /// session titles have.
    private static func makeTitle(from messages: [SessionMessage]) -> String {
        return SessionTitle.from(messages: messages) ?? "Imported chat"
    }

    private static func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
