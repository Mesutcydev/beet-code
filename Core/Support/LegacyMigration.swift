import Foundation
import Security

/// One-time data migration for the LocalForge → BeetCode rename.
///
/// The rename changed Keychain service names and the Application Support
/// folder name. Without a migration, ~87 AES-GCM-encrypted sessions, every
/// BYOK API key, the Hugging Face token, and all downloaded models would be
/// orphaned on first launch of the renamed app.
///
/// Behavior:
/// - Keychain items are COPIED old service → new service (same raw bytes —
///   session files decrypt identically because the key value is unchanged).
///   Legacy items are deliberately kept as a rollback safety net.
/// - The Application Support folder is moved only when the legacy folder
///   exists and the new one does not.
/// - Fully idempotent; safe to call on every launch.
/// - Never runs under XCTest (tests use deterministic in-memory seams).
enum LegacyMigration {

    static let legacyAppSupportName = "LocalForge"
    static let appSupportName = "BeetCode"

    /// Keychain services copied old → new: session encryption key, the HF
    /// token, and every BYOK provider API key.
    private static let keychainRenames: [(legacy: String, current: String)] = {
        var pairs: [(String, String)] = [
            ("com.localforge.session-key", "com.beetcode.session-key"),
            ("com.localforge.huggingface", "com.beetcode.huggingface"),
        ]
        for provider in LLMProvider.allCases {
            pairs.append((
                "com.localforge.provider.\(provider.rawValue)",
                "com.beetcode.provider.\(provider.rawValue)"))
        }
        return pairs
    }()

    /// Entry point — call once during app startup, before SessionStore /
    /// ModelStore / providers are touched.
    static func runOnce() {
        guard !Keychain.runningUnderXCTest else { return }
        migrateKeychainItems()
        migrateAppSupportFolder()
    }

    /// Renames whose destination item is still missing — i.e. the silent
    /// startup copy could not migrate them (legacy items ACL-bound to an old
    /// ad-hoc signature refuse non-interactive reads). The Settings UI turns
    /// this into one bounded "Restore keys" action with a visible Keychain
    /// prompt instead of a silent loss.
    static func pendingInteractiveRenames() -> [(legacy: String, current: String)] {
        keychainRenames.filter { _, current in
            !itemExists(service: current)
        }
    }

    /// True when at least one legacy item still needs the interactive copy.
    static func needsInteractiveKeyMigration() -> Bool {
        !pendingInteractiveRenames().isEmpty
    }

    /// Copies legacy Keychain items WITH authorization allowed: macOS shows
    /// its Keychain prompt ("Always Allow" applies it once for all items).
    /// Returns the number of items actually migrated so the UI can confirm.
    /// Runs the same destination-exists guard as the silent path — never
    /// overwrites a key the user already re-entered.
    @discardableResult
    static func migrateInteractively() -> Int {
        guard !Keychain.runningUnderXCTest else { return 0 }
        var migrated = 0
        for (legacy, current) in pendingInteractiveRenames() {
            migrated += copyGenericPasswords(
                from: legacy, to: current, allowAuthenticationUI: true)
        }
        if migrated > 0 {
            Log.app.info("Interactive keychain migration restored \(migrated) item(s)")
        }
        return migrated
    }

    /// Existence probe that never prompts: attribute-only query without
    /// kSecReturnData. ACL-protected items still answer attribute queries.
    private static func itemExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Keychain

    private static func migrateKeychainItems() {
        for (legacy, current) in keychainRenames {
            _ = copyGenericPasswords(from: legacy, to: current)
        }
    }

    /// Copies every generic-password item of one service into another,
    /// account by account, skipping accounts that already exist at the
    /// destination. Fail-fast reads only — never blocks on a prompt.
    /// `allowAuthenticationUI: true` permits the Keychain authorization
    /// dialog (interactive restore path); the bulk listing can itself be
    /// ACL-blocked, so interactive mode also probes the known accounts
    /// individually.
    private static func copyGenericPasswords(
        from legacyService: String,
        to newService: String,
        allowAuthenticationUI: Bool = false
    ) -> Int {
        var migrated = 0
        // Silent mode: never block on a Keychain authorization prompt.
        // Interactive mode: omit the key entirely — the default behavior
        // permits the system prompt (kSecUseAuthenticationUIAllow itself is
        // deprecated since macOS 11).
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if !allowAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                guard let data = item[kSecValueData as String] as? Data,
                      let account = item[kSecAttrAccount as String] as? String
                else { continue }
                if writeMigrated(data: data, account: account, service: newService) {
                    migrated += 1
                }
            }
            return migrated
        }

        // Bulk listing was refused (ACL-bound legacy items). Interactive mode:
        // probe each known account directly so the authorization dialog names
        // a concrete item.
        guard allowAuthenticationUI else { return 0 }
        for account in ["api-key", "local", "default-token"] {
            var itemQuery = query
            itemQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            itemQuery[kSecAttrAccount as String] = account
            var single: CFTypeRef?
            guard SecItemCopyMatching(itemQuery as CFDictionary, &single) == errSecSuccess,
                  let data = single as? Data
            else { continue }
            if writeMigrated(data: data, account: account, service: newService) {
                migrated += 1
            }
        }
        return migrated
    }

    /// Writes one migrated item, honoring the never-overwrite rule. Returns
    /// true when the destination was actually populated.
    private static func writeMigrated(data: Data, account: String, service: String) -> Bool {
        var check: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Destination already populated → never overwrite.
        if SecItemCopyMatching(check as CFDictionary, nil) == errSecSuccess { return false }
        check[kSecValueData as String] = data
        check[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(check as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Application Support

    static func migrateAppSupportFolder() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        migrateFolder(
            from: base.appendingPathComponent(legacyAppSupportName, isDirectory: true),
            to: base.appendingPathComponent(appSupportName, isDirectory: true))
    }

    /// Pure folder move: only when the legacy folder exists and the new one
    /// does not. Separated for testability.
    static func migrateFolder(from legacy: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: new.path)
        else { return }
        try? fm.moveItem(at: legacy, to: new)
    }
}
