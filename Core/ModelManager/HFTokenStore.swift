import Foundation
import Security

/// Stores the Hugging Face access token in the Keychain (never UserDefaults)
/// and validates it against the Hub's `whoami-v2` endpoint.
@MainActor
final class HFTokenStore: ObservableObject {

    struct WhoAmI: Codable, Sendable, Equatable {
        struct UserInfo: Codable, Sendable, Equatable {
            let name: String?
        }
        let name: String?
        let type: String?
    }

    enum TokenError: Error, LocalizedError, Equatable {
        case tokenRequired
        case tokenRejected
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .tokenRequired:
                return "Add a Hugging Face access token in Settings to download from gated or rate-limited repos."
            case .tokenRejected:
                return "Hugging Face rejected this token. Check that it is valid and has read access."
            case .invalidResponse:
                return "Unexpected response from Hugging Face while validating the token."
            }
        }
    }

    static let shared = HFTokenStore()

    /// Thread-safe token read for background subsystems. Cached in memory
    /// after the first read so repeated downloads never re-prompt the
    /// keychain.
    nonisolated static let tokenCacheLock = NSLock()
    nonisolated static let tokenReadLock = NSLock()
    nonisolated(unsafe) private static var cachedToken: String?
    nonisolated(unsafe) private static var tokenWasRead = false

    nonisolated static func currentToken() -> String? {
        tokenReadLock.lock()
        defer { tokenReadLock.unlock() }
        tokenCacheLock.lock()
        if tokenWasRead {
            let cached = cachedToken
            tokenCacheLock.unlock()
            return cached
        }
        tokenCacheLock.unlock()
        let value = Keychain.read(service: "com.beetcode.huggingface", account: "default-token")
        tokenCacheLock.lock()
        cachedToken = value
        tokenWasRead = true
        tokenCacheLock.unlock()
        return value
    }

    /// Invalidates the in-memory token cache (e.g. after the user changes or
    /// removes the token).
    nonisolated static func invalidateTokenCache() {
        tokenCacheLock.lock()
        cachedToken = nil
        tokenWasRead = false
        tokenCacheLock.unlock()
    }
    /// nil = unknown, false = no token, true = validated
    @Published private(set) var validated: Bool?
    @Published private(set) var username: String?

    private let service = "com.beetcode.huggingface"
    private let account = "default-token"

    var hasToken: Bool { Self.currentToken() != nil }

    func token() -> String? {
        Self.currentToken()
    }

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.write(trimmed, service: service, account: account)
        Self.invalidateTokenCache()
        validated = nil
        username = nil
    }

    func deleteToken() {
        Keychain.delete(service: service, account: account)
        Self.invalidateTokenCache()
        validated = false
        username = nil
    }

    /// Validates an arbitrary token WITHOUT persisting it; returns the
    /// account name on success. Used by Settings to test a draft before it is
    /// stored, so an invalid token is never left in the Keychain.
    func validate(draft: String) async throws -> String {
        let token = draft.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            throw TokenError.tokenRequired
        }
        return try await Self.check(token: token)
    }

    /// Validates the stored token; returns the account name on success.
    func validate() async throws -> String {
        guard let token = token() else {
            validated = false
            throw TokenError.tokenRequired
        }
        let name = try await Self.check(token: token)
        validated = true
        username = name
        return name
    }

    private static func check(token: String) async throws -> String {

        var request = URLRequest(url: URL(string: "https://huggingface.co/api/whoami-v2")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw TokenError.invalidResponse }
        switch http.statusCode {
        case 200:
            let whoami = try? JSONDecoder().decode(WhoAmI.self, from: data)
            let name = whoami?.name ?? "unknown"
            Log.app.info("HF token validated for \(name, privacy: .public)")
            return name
        case 401, 403:
            throw TokenError.tokenRejected
        default:
            throw TokenError.invalidResponse
        }
    }
}

/// Minimal Keychain generic-password wrapper. Tokens are credentials, not
/// preferences — they belong in the Keychain, scoped to this device only.
enum Keychain {
    // Under the XCTest runner the real Keychain blocks on securityd IPC /
    // invisible authorization prompts (ad-hoc re-signs re-prompt after every
    // binary change), hanging the suite. Tests get an in-memory store with
    // identical semantics; the production app keeps using the real Keychain.
    // Detection mirrors SessionCrypto.key(): env var (xcodebuild test host)
    // OR XCTest.framework loaded (standalone `xcrun xctest`).
    static var runningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static let testLock = NSLock()
    nonisolated(unsafe) private static var testStore: [String: String] = [:]
    private static func testKey(_ service: String, _ account: String) -> String {
        "\(service)/\(account)"
    }

    static func read(service: String, account: String) -> String? {
        if Self.runningUnderXCTest {
            testLock.lock()
            defer { testLock.unlock() }
            return testStore[testKey(service, account)]
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Never block on a Keychain authorization prompt: a missing ACL
            // returns errSecInteractionNotAllowed instead of hanging the
            // caller (which, for a startup probe, would freeze the app).
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        if Self.runningUnderXCTest {
            testLock.lock()
            defer { testLock.unlock() }
            testStore[testKey(service, account)] = value
            return
        }
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.app.error("Keychain write failed: \(String(describing: status), privacy: .public)")
        }
    }

    static func delete(service: String, account: String) {
        if Self.runningUnderXCTest {
            testLock.lock()
            defer { testLock.unlock() }
            testStore[testKey(service, account)] = nil
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
