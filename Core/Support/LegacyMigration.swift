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

    // MARK: Keychain

    private static func migrateKeychainItems() {
        for (legacy, current) in keychainRenames {
            copyGenericPasswords(from: legacy, to: current)
        }
    }

    /// Copies every generic-password item of one service into another,
    /// account by account, skipping accounts that already exist at the
    /// destination. Fail-fast reads only — never blocks on a prompt.
    private static func copyGenericPasswords(from legacyService: String, to newService: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return }

        for item in items {
            guard let data = item[kSecValueData as String] as? Data,
                  let account = item[kSecAttrAccount as String] as? String
            else { continue }

            var check: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: newService,
                kSecAttrAccount as String: account,
            ]
            // Destination already populated → never overwrite.
            if SecItemCopyMatching(check as CFDictionary, nil) == errSecSuccess { continue }
            check[kSecValueData as String] = data
            check[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(check as CFDictionary, nil)
        }
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
