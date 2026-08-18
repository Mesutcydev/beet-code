import Foundation

/// User-facing durable preferences, restored at launch after validation.
/// Everything here is a *selection* (workspace, model, session) — the
/// stores themselves remain the source of truth for the data.
struct AppPreferences: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var lastWorkspacePath: String?
    /// Security-scoped bookmark data for the workspace, where available.
    var workspaceBookmarkData: Data?
    /// Last successfully loaded model (only restored when still installed).
    var lastModelID: String?
    /// Session that was active when the app quit.
    var lastSessionID: UUID?
    /// Whether incomplete downloads should resume automatically at launch.
    var autoResumeDownloads: Bool = false
    /// Last chosen model per BYOK provider (v0.3).
    var remoteModel: [String: String] = [:]
    /// Base URL for the `.custom` OpenAI-compatible provider (v0.6).
    var customBaseURL: String?
}

/// JSON-file-backed preferences under Application Support/BeetCode.
final class AppPreferencesStore: @unchecked Sendable {

    static let shared = AppPreferencesStore()

    private let lock = NSLock()
    private var cached: AppPreferences?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeetCode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("preferences.json")
    }

    var current: AppPreferences {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = Self.load(from: fileURL)
        cached = loaded
        return loaded
    }

    func save(_ preferences: AppPreferences) {
        lock.lock()
        cached = preferences
        let url = fileURL
        lock.unlock()
        Self.write(preferences, to: url)
    }

    /// Validates the stored workspace and returns a restore-safe URL.
    /// Fails silently (returns nil) without touching the stored state.
    func validatedWorkspaceURL() -> URL? {
        let preferences = current
        guard let path = preferences.lastWorkspacePath, !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: path)
        if let bookmark = preferences.workspaceBookmarkData {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale) {
                url = resolved
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return url
    }

    /// Creates a security-scoped bookmark for the workspace where the OS
    /// supports it; non-sandboxed apps can ignore the result.
    func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    // MARK: IO

    private static func load(from url: URL) -> AppPreferences {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else { return AppPreferences() }
        return decoded
    }

    private static func write(_ preferences: AppPreferences, to url: URL) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        try? data.write(to: url, options: .atomic)
    }
}