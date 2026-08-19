import CryptoKit
import Foundation
import Network

/// OAuth 2.0 for MCP HTTP servers (spec 2025-03-26 §authorization):
/// authorization-server metadata discovery, Dynamic Client Registration
/// (RFC 7591), Authorization Code + PKCE with a loopback redirect, token
/// storage in the Keychain, and automatic refresh.
///
/// All request/URL construction is pure (`Planner`) and unit-testable; the
/// network + browser + loopback pieces are thin wrappers around it.

// MARK: - Pure planner

enum MCPOAuthPlanner {

    /// RFC 7636 verifier: 43–128 chars from the unreserved set, base64url
    /// of 32 random bytes.
    static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(bytes)
    }

    /// S256 challenge: base64url(SHA-256(verifier)).
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Array(digest))
    }

    static func base64URLEncode(_ bytes: [UInt8]) -> String {
        Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The authorization URL the user's browser must open.
    static func authorizationURL(
        metadata: MCPOAuthMetadata,
        clientID: String,
        redirectURI: String,
        codeVerifier: String,
        state: String
    ) -> URL? {
        guard var components = URLComponents(string: metadata.authorizationEndpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url
    }

    /// Body for the token exchange (POST, form-encoded per RFC 6749 §4.1.3).
    static func tokenRequestParams(
        metadata: MCPOAuthMetadata,
        code: String,
        codeVerifier: String,
        clientID: String,
        clientSecret: String?,
        redirectURI: String
    ) -> [String: String] {
        var params: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
        ]
        if let clientSecret { params["client_secret"] = clientSecret }
        return params
    }

    /// Body for a refresh (RFC 6749 §6).
    static func refreshRequestParams(
        refreshToken: String,
        clientID: String,
        clientSecret: String?
    ) -> [String: String] {
        var params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let clientSecret { params["client_secret"] = clientSecret }
        return params
    }

    /// Refresh a little before true expiry so requests never race the edge.
    static func shouldRefresh(tokens: MCPOAuthTokens, now: Date = Date(), skew: TimeInterval = 30) -> Bool {
        guard let expiresAt = tokens.expiresAt else { return false }
        return now >= expiresAt.addingTimeInterval(-skew)
    }

    /// Discovery URLs for a server (resource-metadata first, then the
    /// historical well-known paths), in preference order.
    static func discoveryURLs(for serverURL: URL) -> [URL] {
        guard let host = serverURL.host else { return [] }
        var schemes = ["https"]
        if serverURL.scheme == "http" { schemes.append("http") }
        var candidates: [URL] = []
        for scheme in schemes {
            candidates.append(URL(string: "\(scheme)://\(host)/.well-known/oauth-authorization-server")!)
            candidates.append(URL(string: "\(scheme)://\(host)/.well-known/oauth-protected-resource")!)
        }
        return candidates
    }
}

// MARK: - Types

/// Authorization-server metadata (RFC 8414 subset).
struct MCPOAuthMetadata: Codable, Equatable, Sendable {
    var authorization_endpoint: String
    var token_endpoint: String
    var registration_endpoint: String?

    enum CodingKeys: String, CodingKey {
        case authorization_endpoint = "authorization_endpoint"
        case token_endpoint = "token_endpoint"
        case registration_endpoint = "registration_endpoint"
    }

    var authorizationEndpoint: String { authorization_endpoint }
    var tokenEndpoint: String { token_endpoint }
    var registrationEndpoint: String? { registration_endpoint }
}

/// Stored token set for one MCP server.
struct MCPOAuthTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

// MARK: - Provider actor

/// Owns the OAuth lifecycle for one HTTP MCP server: discovery, client
/// registration, the PKCE authorization round-trip through the user's
/// browser, token persistence in the Keychain, and refresh.
actor MCPOAuthProvider {

    enum OAuthError: Error, LocalizedError, Equatable {
        case discoveryFailed
        case registrationFailed(String)
        case authorizationFailed(String)
        case tokenExchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .discoveryFailed: "Could not discover the MCP server's OAuth metadata."
            case .registrationFailed(let detail): "OAuth client registration failed: \(detail)"
            case .authorizationFailed(let detail): "OAuth authorization failed: \(detail)"
            case .tokenExchangeFailed(let detail): "OAuth token exchange failed: \(detail)"
            }
        }
    }

    private let serverName: String
    private let configuredClientID: String?
    private let configuredClientSecret: String?
    private var registeredClientID: String?
    private var tokens: MCPOAuthTokens?
    private var metadata: MCPOAuthMetadata?
    private(set) var didHandleUnauthorized = false
    private let session = URLSession(configuration: .ephemeral)

    init(serverName: String, clientID: String? = nil, clientSecret: String? = nil) {
        self.serverName = serverName
        self.configuredClientID = clientID
        self.configuredClientSecret = clientSecret
        self.registeredClientID = clientID
        self.tokens = Self.loadTokens(serverName: serverName)
    }

    /// Marks that one 401 has already triggered the OAuth retry this session.
    func markUnauthorizedHandled() {
        didHandleUnauthorized = true
    }

    var hasTokens: Bool {
        tokens != nil
    }

    // MARK: Applying auth to requests

    /// Attaches a valid Bearer token, refreshing first when expired.
    func apply(to request: inout URLRequest) async throws {
        guard var current = tokens else { return }  // anonymous request
        if MCPOAuthPlanner.shouldRefresh(tokens: current), current.refreshToken != nil, let metadata {
            if let refreshed = try? await refresh(tokens: current, metadata: metadata) {
                current = refreshed
                tokens = refreshed
                Self.saveTokens(refreshed, serverName: serverName)
            }
        }
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
    }

    // MARK: Full authorization flow (called on 401)

    func handleUnauthorized(for serverURL: URL) async throws {
        let metadata = try await discover(for: serverURL)
        self.metadata = metadata

        let clientID = try await resolveClientID(metadata: metadata)
        let redirectURI = "http://127.0.0.1:31280/callback"
        let verifier = MCPOAuthPlanner.makeCodeVerifier()
        let state = MCPOAuthPlanner.makeCodeVerifier()

        guard let authURL = MCPOAuthPlanner.authorizationURL(
            metadata: metadata, clientID: clientID, redirectURI: redirectURI,
            codeVerifier: verifier, state: state)
        else {
            throw OAuthError.authorizationFailed("could not build authorization URL")
        }

        // Start the loopback listener concurrently, THEN open the browser —
        // awaiting the callback before opening the browser would deadlock.
        async let callback = waitForCallback(state: state)
        #if canImport(AppKit)
        _ = await MainActor.run {
            NSWorkspace.shared.open(authURL)
        }
        #endif

        guard let code = await callback else {
            throw OAuthError.authorizationFailed("no authorization code received")
        }

        let params = MCPOAuthPlanner.tokenRequestParams(
            metadata: metadata, code: code, codeVerifier: verifier,
            clientID: clientID, clientSecret: configuredClientSecret, redirectURI: redirectURI)
        let exchanged = try await postForm(to: metadata.tokenEndpoint, params: params)
        tokens = exchanged
        Self.saveTokens(exchanged, serverName: serverName)
    }

    // MARK: Discovery + registration

    func discover(for serverURL: URL) async throws -> MCPOAuthMetadata {
        if let metadata { return metadata }
        for candidate in MCPOAuthPlanner.discoveryURLs(for: serverURL) {
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 10
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let metadata = try? JSONDecoder().decode(MCPOAuthMetadata.self, from: data) {
                self.metadata = metadata
                return metadata
            }
        }
        throw OAuthError.discoveryFailed
    }

    /// Uses the configured client id, or registers one dynamically (RFC 7591).
    private func resolveClientID(metadata: MCPOAuthMetadata) async throws -> String {
        if let registeredClientID { return registeredClientID }
        guard let endpoint = metadata.registrationEndpoint else {
            throw OAuthError.registrationFailed("no client id configured and no registration endpoint")
        }
        let body = LFJSONValue.object([
            "client_name": .string("Beet Code"),
            "redirect_uris": .array([.string("http://127.0.0.1:31280/callback")]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ])
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.encoded().utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? LFJSONValue.decode(data),
              let clientID = json.objectValue?["client_id"]?.stringValue
        else {
            throw OAuthError.registrationFailed("HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
        }
        registeredClientID = clientID
        return clientID
    }

    // MARK: Token exchange + refresh

    private func refresh(tokens current: MCPOAuthTokens, metadata: MCPOAuthMetadata) async throws -> MCPOAuthTokens {
        guard let refreshToken = current.refreshToken else { return current }
        let clientID = registeredClientID ?? configuredClientID ?? ""
        let params = MCPOAuthPlanner.refreshRequestParams(
            refreshToken: refreshToken, clientID: clientID, clientSecret: configuredClientSecret)
        return try await postForm(to: metadata.tokenEndpoint, params: params)
    }

    private func postForm(to endpoint: String, params: [String: String]) async throws -> MCPOAuthTokens {
        guard let url = URL(string: endpoint) else {
            throw OAuthError.tokenExchangeFailed("invalid token endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(params).utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.tokenExchangeFailed("HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
        }
        guard let json = try? LFJSONValue.decode(data), let object = json.objectValue,
              let accessToken = object["access_token"]?.stringValue
        else {
            throw OAuthError.tokenExchangeFailed("malformed token response")
        }
        var expiresAt: Date?
        if let expiresIn = object["expires_in"]?.numberValue {
            expiresAt = Date().addingTimeInterval(expiresIn)
        }
        return MCPOAuthTokens(
            accessToken: accessToken,
            refreshToken: object["refresh_token"]?.stringValue,
            expiresAt: expiresAt)
    }

    nonisolated static func formEncode(_ params: [String: String]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    // MARK: Loopback callback listener

    /// Listens on the redirect port for the authorization callback; returns
    /// the `code` parameter once the browser lands (validated against state).
    private func waitForCallback(state expectedState: String) async -> String? {
        await withCheckedContinuation { continuation in
            let listener = LoopbackOAuthListener(expectedState: expectedState) { code in
                continuation.resume(returning: code)
            }
            listener.start()
            // Safety timeout: never hang the agent on a browser that never returns.
            Task {
                try? await Task.sleep(for: .seconds(180))
                listener.stop()
            }
        }
    }

    // MARK: Persistence (Keychain)

    private static func tokensAccount(serverName: String) -> String {
        "mcp-oauth-\(serverName)"
    }

    private static func loadTokens(serverName: String) -> MCPOAuthTokens? {
        guard let raw = Keychain.read(service: "com.beetcode.mcp-oauth", account: tokensAccount(serverName: serverName)),
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(MCPOAuthTokens.self, from: data)
    }

    private static func saveTokens(_ tokens: MCPOAuthTokens, serverName: String) {
        guard let data = try? JSONEncoder().encode(tokens),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        Keychain.write(raw, service: "com.beetcode.mcp-oauth", account: tokensAccount(serverName: serverName))
    }
}

// MARK: - Loopback listener

/// Minimal one-shot HTTP listener on the loopback interface that captures the
/// OAuth redirect (`?code=…&state=…`) and answers with a small "you can close
/// this tab" page. Network.framework keeps this dependency-free.
final class LoopbackOAuthListener: @unchecked Sendable {

    private let expectedState: String
    private let onCode: @Sendable (String?) -> Void
    private var listener: NWListener?
    private let lock = NSLock()
    private var resumed = false

    init(expectedState: String, onCode: @escaping @Sendable (String?) -> Void) {
        self.expectedState = expectedState
        self.onCode = onCode
    }

    func start() {
        guard let port = NWEndpoint.Port(rawValue: 31280),
              let listener = try? NWListener(using: .tcp, on: port)
        else {
            finish(nil)
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { state in
            if case .failed = state { self.finish(nil) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        finish(nil)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveMore(on: connection, received: Data())
    }

    /// Accumulates the HTTP request by value across receives — no captured
    /// mutable state in the @Sendable completion handler.
    private func receiveMore(on connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
            var accumulated = received
            if let data { accumulated.append(data) }
            // The request line is enough: GET /callback?code=…&state=… HTTP/1.1
            if let requestText = String(data: accumulated, encoding: .utf8),
               requestText.contains("\r\n") || error != nil {
                self.respond(to: requestText, on: connection)
            } else if error == nil {
                self.receiveMore(on: connection, received: accumulated)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to requestText: String, on connection: NWConnection) {
        var code: String?
        if let firstLine = requestText.split(separator: "\r\n").first ?? requestText.split(separator: "\n").first,
           let queryStart = firstLine.firstIndex(of: "?") {
            let query = String(firstLine[firstLine.index(after: queryStart)...])
                .split(separator: " ").first.map(String.init) ?? ""
            var stateOK = expectedState.isEmpty
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0] == "code" { code = parts[1] }
                if parts[0] == "state" { stateOK = parts[1] == expectedState }
            }
            if !stateOK { code = nil }  // CSRF guard: reject mismatched state
        }
        let body = """
        <html><body style="font-family:-apple-system;padding:40px">
        <h2>Beet Code</h2><p>Authorization complete — you can close this tab.</p>
        </body></html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [code] _ in
            connection.cancel()
            self.finish(code)
        })
    }

    private func finish(_ code: String?) {
        lock.lock()
        let already = resumed
        resumed = true
        lock.unlock()
        guard !already else { return }
        listener?.cancel()
        onCode(code)
    }
}

#if canImport(AppKit)
import AppKit
#endif
