import CryptoKit
import Foundation
import Security

/// A git checkpoint taken immediately before an approved edit batch executes.
/// Stored with the session so "undo last agent action" survives relaunch.
struct SessionCheckpoint: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var treeSHA: String
    var createdAt: Date
    var summary: String
}

struct SessionMessage: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case toolCall
        case toolResult
        case system
    }

    var role: Role
    var content: String
    var toolName: String?
    var timestamp: Date
}

struct SessionRecord: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var workspacePath: String
    var modelID: String
    var messages: [SessionMessage]
    var checkpoints: [SessionCheckpoint]
    /// Optional schema version. Absent on records written by the original
    /// store — those are v1 and migrated on next save.
    var schemaVersion: Int?

    static let currentSchemaVersion = 2
}

/// Symmetric encryption for session payloads using a Keychain-held local key.
/// Payload format: magic "LFS1" + nonce(12) + AES-GCM sealed box.
enum SessionCrypto {

    private static let magic = Data([0x4C, 0x46, 0x53, 0x31])  // "LFS1"
    private static let keychainService = "com.beetcode.session-key"
    private static let keychainAccount = "local"

    // The Keychain key is read ONCE and cached in memory: at launch the
    // session store decrypts every session file, and each raw SecItem access
    // can trigger a keychain password prompt on an ad-hoc-signed build.
    private static let keyCacheLock = NSLock()
    // All access happens under keyCacheLock.
    private static nonisolated(unsafe) var cachedKey: SymmetricKey?
    /// Test seam: bypass the Keychain entirely (tests must be deterministic —
    //  and ad-hoc re-signs make Keychain ACLs re-prompt, which blocks).
    static nonisolated(unsafe) var overrideKey: SymmetricKey?

    static var isAvailable: Bool {
        (try? key(interactionAllowed: false)) != nil
    }

    static func encrypt(_ payload: Data) -> Data? {
        guard let key = try? key(interactionAllowed: false) else { return nil }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(payload, using: key, nonce: nonce)
            var box = magic
            box.append(nonce.withUnsafeBytes { Data($0) })
            box.append(sealed.ciphertext)
            box.append(sealed.tag)
            return box
        } catch {
            return nil
        }
    }

    static func decrypt(_ data: Data) -> Data? {
        guard data.count > magic.count + 12,
              data.prefix(magic.count) == magic,
              let key = try? key(interactionAllowed: false)
        else { return nil }
        do {
            var offset = data.startIndex + magic.count
            let nonceData = data[offset..<(offset + 12)]
            offset += 12
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let ciphertext = data[offset..<(data.count - 16)]
            let tag = data[(data.count - 16)...]
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            return nil
        }
    }

    /// True when the last non-interactive key read failed because the
    /// Keychain wants user authorization (ad-hoc re-signed builds re-prompt
    /// after every binary change). Lets the UI offer one bounded interactive
    /// retry instead of hanging on a prompt nobody can see.
    private static nonisolated(unsafe) var needsInteractiveUnlockState = false

    static var needsInteractiveUnlock: Bool {
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        return needsInteractiveUnlockState
    }

    private static func setNeedsInteractiveUnlock(_ value: Bool) {
        keyCacheLock.lock()
        needsInteractiveUnlockState = value
        keyCacheLock.unlock()
    }

    /// One-time interactive unlock. MUST run where a Keychain prompt can
    /// actually be seen (the app's main window); caches the key on success.
    @discardableResult
    static func unlockInteractively() -> Bool {
        if (try? key(interactionAllowed: true)) != nil {
            setNeedsInteractiveUnlock(false)
            return true
        }
        return false
    }

    /// - Parameter interactionAllowed: false = never block on a Keychain
    ///   authorization dialog (skip-UI read, fail fast); true = the prompt may
    ///   appear (interactive contexts only).
    private static func key(interactionAllowed: Bool) throws -> SymmetricKey {
        // Test seam: deterministic key, no Keychain.
        if let override = overrideKey { return override }
        // Under the XCTest runner, Keychain ACLs are unreliable (ad-hoc
        // re-signs re-prompt invisibly and hang the suite) and tests must be
        // deterministic: self-install a process-local key the first time it
        // is needed. Never active outside the test runner. Detection covers
        // both the xcodebuild test host (XCTest injected via the bundle) and
        // the standalone `xcrun xctest` runner (no configuration-file env
        // var there, but XCTest.framework is always loaded when tests run).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            let testKey = SymmetricKey(size: .bits256)
            overrideKey = testKey
            return testKey
        }
        // Fast path: reuse the cached key (no keychain access).
        keyCacheLock.lock()
        if let cached = cachedKey {
            keyCacheLock.unlock()
            return cached
        }
        keyCacheLock.unlock()

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !interactionAllowed {
            // Fail fast instead of blocking on an invisible authorization
            // prompt — a hang here froze the whole app at launch.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            let key = SymmetricKey(data: data)
            keyCacheLock.lock()
            cachedKey = key
            keyCacheLock.unlock()
            setNeedsInteractiveUnlock(false)
            return key
        }
        if status == errSecInteractionNotAllowed {
            setNeedsInteractiveUnlock(true)
            throw SessionCryptoError.keyStorageFailed(status)
        }
        if status == errSecItemNotFound {
            var newKey = Data(count: 32)
            let result = newKey.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard result == errSecSuccess else {
                throw SessionCryptoError.keyGenerationFailed
            }
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecValueData as String: newKey,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SessionCryptoError.keyStorageFailed(addStatus)
            }
            let key = SymmetricKey(data: newKey)
            keyCacheLock.lock()
            cachedKey = key
            keyCacheLock.unlock()
            return key
        }
        throw SessionCryptoError.keyStorageFailed(status)
    }

    /// Test seam — clears the in-memory key cache.
    static func resetCache() {
        keyCacheLock.lock()
        cachedKey = nil
        keyCacheLock.unlock()
    }

    enum SessionCryptoError: Error {
        case keyGenerationFailed
        case keyStorageFailed(OSStatus)
    }
}

/// JSON-file-backed session persistence under Application Support/BeetCode.
/// Sessions are encrypted with a Keychain-held key; the sessions directory
/// is additionally chmod 0700 as defense in depth.
final class SessionStore: @unchecked Sendable {

    static let shared = SessionStore()

    private let lock = NSLock()

    /// Test seam: redirects the sessions directory away from the real
    /// Application Support folder.
    var overrideSessionsDir: URL?

    private var sessionsDir: URL {
        if let override = overrideSessionsDir {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeetCode/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    private func url(for id: UUID) -> URL {
        sessionsDir.appendingPathComponent("\(id.uuidString).session")
    }

    /// The session the user was working in last; nil when none or invalid.
    var currentSessionID: UUID? {
        get { AppPreferencesStore.shared.current.lastSessionID }
        set {
            var preferences = AppPreferencesStore.shared.current
            preferences.lastSessionID = newValue
            AppPreferencesStore.shared.save(preferences)
        }
    }

    // MARK: Persistence

    func save(_ record: SessionRecord) {
        var record = record
        record.schemaVersion = SessionRecord.currentSchemaVersion
        // Bounded retention: sensitive command output and arguments are
        // redacted and oversized tool results are truncated before writing.
        record.messages = Self.redactAndBound(record.messages)
        let target = url(for: record.id)
        // Encrypt + write OUTSIDE the store lock: encryption can block on
        // Keychain/securityd IPC, and holding the lock across it deadlocks
        // every concurrent load().
        guard let data = try? JSONEncoder().encode(record) else { return }
        let payload = SessionCrypto.encrypt(data) ?? data
        try? payload.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    func load(id: UUID) -> SessionRecord? {
        // File IO + decrypt outside the lock (same rationale as save()).
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        if let decrypted = SessionCrypto.decrypt(data),
           let record = try? JSONDecoder().decode(SessionRecord.self, from: decrypted) {
            lock.lock()
            defer { lock.unlock() }
            return migrateIfNeeded(record)
        }
        if let record = try? JSONDecoder().decode(SessionRecord.self, from: data) {
            // Legacy plaintext: re-save encrypted on next save; decode now.
            return migrateIfNeeded(record)
        }
        return nil
    }

    func loadAll() -> [SessionRecord] {
        // Snapshot filenames under the lock, then do file IO + Keychain-backed
        // decryption OUTSIDE it. Holding the lock across decrypt could deadlock
        // any concurrent save() when a Keychain authorization prompt blocks
        // (ad-hoc re-signed builds re-prompt on every binary change).
        let dir = sessionsDir
        let names: [String]
        lock.lock()
        names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        lock.unlock()
        return names
            .filter { $0.hasSuffix(".session") }
            .compactMap { name in
                let id = UUID(uuidString: String(name.dropLast(".session".count)))
                guard let id else { return nil }
                let url = dir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { return nil }
                if let decrypted = SessionCrypto.decrypt(data),
                   let record = try? JSONDecoder().decode(SessionRecord.self, from: decrypted) {
                    return migrateIfNeeded(record)
                }
                return try? JSONDecoder().decode(SessionRecord.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(_ record: SessionRecord) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(for: record.id))
    }

    /// True when the session's workspace binding still exists on disk.
    func validateWorkspaceBinding(_ record: SessionRecord) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: record.workspacePath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: Migration

    private func migrateIfNeeded(_ record: SessionRecord) -> SessionRecord {
        // v1 → current: nothing structural changed yet; the version field is
        // stamped on next save. Future migrations branch here.
        record
    }

    // MARK: Redaction

    /// Scrubs obvious credentials from tool calls/results and bounds the size
    /// of persisted tool outputs.
    static func redactAndBound(_ messages: [SessionMessage], maxToolResultBytes: Int = 16_384) -> [SessionMessage] {
        messages.map { message in
            guard message.role == .toolCall || message.role == .toolResult else { return message }
            var scrubbed = message
            scrubbed.content = redact(message.content)
            if scrubbed.content.utf8.count > maxToolResultBytes {
                scrubbed.content = String(scrubbed.content.prefix(maxToolResultBytes))
                    + "\n…[truncated for persistence]…"
            }
            return scrubbed
        }
    }

    static func redact(_ text: String) -> String {
        var result = text
        for pattern in Self.secretPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: "[redacted]")
            }
        }
        return result
    }

    private static let secretPatterns: [String] = [
        // Hugging Face tokens.
        "hf_[A-Za-z0-9]{10,}",
        // GitHub tokens.
        "ghp_[A-Za-z0-9]{20,}",
        "github_pat_[A-Za-z0-9_]{20,}",
        // Slack tokens.
        "xox[baprs]-[A-Za-z0-9-]{10,}",
        // Generic API keys.
        "sk-[A-Za-z0-9]{16,}",
        "AKIA[0-9A-Z]{16}",
        // Bearer headers.
        "(?i)bearer\\s+[A-Za-z0-9._~+/=-]{16,}",
        // Authorization lines.
        "(?i)authorization:\\s*[^\\n]{6,}",
    ]
}