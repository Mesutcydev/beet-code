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
    /// Optional capability overrides keyed by `provider:model`.
    var remoteModelOverrides: [String: RemoteModelOverride] = [:]
    /// Last provider metadata observed from a live `/models` catalog. This is
    /// cacheable, non-secret data and lets the composer stay honest offline.
    var remoteModelProfiles: [String: RemoteModelProfile] = [:]
    /// Tasks the user pinned in the sidebar. This is intentionally an id list
    /// rather than a copy of session data, so deleting a chat cannot leave a
    /// second stale task record behind.
    var pinnedSessionIDs: [UUID] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, lastWorkspacePath, workspaceBookmarkData, lastModelID,
             lastSessionID, autoResumeDownloads, remoteModel, customBaseURL,
             remoteModelOverrides, remoteModelProfiles, pinnedSessionIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        lastWorkspacePath = try container.decodeIfPresent(String.self, forKey: .lastWorkspacePath)
        workspaceBookmarkData = try container.decodeIfPresent(Data.self, forKey: .workspaceBookmarkData)
        lastModelID = try container.decodeIfPresent(String.self, forKey: .lastModelID)
        lastSessionID = try container.decodeIfPresent(UUID.self, forKey: .lastSessionID)
        autoResumeDownloads = try container.decodeIfPresent(Bool.self, forKey: .autoResumeDownloads) ?? false
        remoteModel = try container.decodeIfPresent([String: String].self, forKey: .remoteModel) ?? [:]
        customBaseURL = try container.decodeIfPresent(String.self, forKey: .customBaseURL)
        remoteModelOverrides = try container.decodeIfPresent(
            [String: RemoteModelOverride].self, forKey: .remoteModelOverrides) ?? [:]
        remoteModelProfiles = try container.decodeIfPresent(
            [String: RemoteModelProfile].self, forKey: .remoteModelProfiles) ?? [:]
        pinnedSessionIDs = try container.decodeIfPresent([UUID].self, forKey: .pinnedSessionIDs) ?? []
    }
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

    func remoteModelOverride(provider: LLMProvider, model: String) -> RemoteModelOverride? {
        current.remoteModelOverrides[remoteModelKey(provider: provider, model: model)]
    }

    func remoteModelOverride(endpoint: RemoteEndpoint) -> RemoteModelOverride? {
        current.remoteModelOverrides[remoteModelKey(endpoint: endpoint)]
            ?? remoteModelOverride(provider: endpoint.provider, model: endpoint.model)
    }

    func remoteModelProfile(provider: LLMProvider, model: String) -> RemoteModelProfile? {
        current.remoteModelProfiles[remoteModelKey(provider: provider, model: model)]
    }

    func remoteModelProfile(endpoint: RemoteEndpoint) -> RemoteModelProfile? {
        current.remoteModelProfiles[remoteModelKey(endpoint: endpoint)]
            ?? remoteModelProfile(provider: endpoint.provider, model: endpoint.model)
    }

    func saveRemoteModelProfiles(_ profiles: [RemoteModelProfile]) {
        guard !profiles.isEmpty else { return }
        var preferences = current
        for profile in profiles {
            preferences.remoteModelProfiles[remoteModelKey(profile: profile)] = profile
        }
        save(preferences)
    }

    func saveRemoteModelOverride(_ override: RemoteModelOverride?, provider: LLMProvider, model: String) {
        var preferences = current
        let key = remoteModelKey(provider: provider, model: model)
        saveRemoteModelOverride(override, key: key, preferences: &preferences)
    }

    /// Saves an override for the exact endpoint identity. OpenCode and other
    /// compatible gateways may use the same model id behind different
    /// provider ids, so a provider-only key would apply the wrong capabilities
    /// to one of them.
    func saveRemoteModelOverride(_ override: RemoteModelOverride?, endpoint: RemoteEndpoint) {
        var preferences = current
        let key = remoteModelKey(endpoint: endpoint)
        saveRemoteModelOverride(override, key: key, preferences: &preferences)
    }

    private func saveRemoteModelOverride(
        _ override: RemoteModelOverride?,
        key: String,
        preferences: inout AppPreferences
    ) {
        if let override, !override.isEmpty {
            preferences.remoteModelOverrides[key] = override
        } else {
            preferences.remoteModelOverrides.removeValue(forKey: key)
        }
        save(preferences)
    }

    private func remoteModelKey(provider: LLMProvider, model: String) -> String {
        "\(provider.rawValue):\(model.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func remoteModelKey(profile: RemoteModelProfile) -> String {
        if let providerKey = profile.providerKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerKey.isEmpty {
            return "opencode:\(providerKey):\(profile.model.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return remoteModelKey(provider: profile.provider, model: profile.model)
    }

    private func remoteModelKey(endpoint: RemoteEndpoint) -> String {
        if let providerID = endpoint.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            return "opencode:\(providerID):\(endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return remoteModelKey(provider: endpoint.provider, model: endpoint.model)
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
