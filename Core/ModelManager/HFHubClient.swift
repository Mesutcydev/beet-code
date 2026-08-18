import CryptoKit
import Foundation

/// A file in a Hugging Face repo, with the metadata the smart downloader needs.
struct HubFile: Sendable, Equatable, Codable {
    let path: String
    let sizeBytes: Int64
    /// ETag identifying the content (git blob sha for regular files, sha256 for LFS).
    let etag: String
    /// SHA-256 for LFS-hosted files (weights); nil for small git files.
    let sha256: String?

    var isWeights: Bool {
        path.hasSuffix(".safetensors") || path.hasSuffix(".npz") || path.hasSuffix(".bin")
    }
}

/// Minimal read-only Hugging Face Hub client over the public HTTP API.
///
/// The token is attached only to `huggingface.co` requests; a custom session
/// delegate strips `Authorization` when a resolve request redirects to the
/// CDN so the credential never leaves Hub infrastructure.

/// The network surface ModelDownloadManager needs — abstracted so tests can
/// serve downloads from local fixture directories.
protocol HubServing: Sendable {
    func listModelFiles(repo: String, revision: String) async throws -> [HubFile]
    func resolveURL(repo: String, path: String, revision: String) -> URL

    func downloadRequest(url: URL, offset: Int64) -> URLRequest
    func response(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse)
}
extension HubServing {
    func listModelFiles(repo: String) async throws -> [HubFile] {
        try await listModelFiles(repo: repo, revision: "main")
    }

    func resolveURL(repo: String, path: String) -> URL {
        resolveURL(repo: repo, path: path, revision: "main")
    }
}

struct HFHubClient: Sendable, HubServing {

    enum HubError: Error, LocalizedError, Equatable {
        case repoNotFound(String)
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .repoNotFound(let repo): return "Repository \(repo) not found on the Hugging Face Hub."
            case .unauthorized: return "Hugging Face rejected the request — check your access token in Settings."
            case .rateLimited(let retryAfter):
                let suffix = retryAfter.map { " Retry in \(Int($0))s." } ?? ""
                return "Rate limited by the Hugging Face Hub.\(suffix)"
            case .badResponse(let detail): return "Unexpected response from the Hub: \(detail)"
            }
        }
    }

    let endpoint: URL
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession

    init(endpoint: URL = URL(string: "https://huggingface.co")!, tokenProvider: @escaping @Sendable () -> String?) {
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600 * 6
        let delegate = RedirectStrippingDelegate()
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: API

    /// Lists repo files matching the model globs, with sizes and content hashes.
    /// Handles cursor pagination via the `Link` header.
    func listModelFiles(repo: String, revision: String = "main") async throws -> [HubFile] {
        var files: [HubFile] = []
        var cursor: String? = nil

        repeat {
            var components = URLComponents(
                url: endpoint.appendingPathComponent("api/models/\(repo)/tree/\(revision)"),
                resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(name: "expand", value: "true"),
            ]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = items

            let (data, response) = try await get(components.url!)
            let page = try decodeTreePage(data)
            files.append(
                contentsOf: page.filter { matchesModelGlobs($0.path) })
            cursor = Self.nextCursor(from: response)
        } while cursor != nil

        return files
    }

    /// URL that serves a file's bytes (redirects to CDN).
    func resolveURL(repo: String, path: String, revision: String = "main") -> URL {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return endpoint.appendingPathComponent("\(repo)/resolve/\(revision)/\(encoded)")
    }

    /// Download request for a byte range; token attached (stripped on CDN redirect).
    func downloadRequest(url: URL, offset: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        request.timeoutInterval = 3600 * 6
        return request
    }

    func response(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HubError.badResponse("not HTTP")
        }
        return (bytes, http)
    }

    /// Streaming SHA-256 of a downloaded file; nil when hashing is unavailable.
    static func sha256Hex(ofFile url: URL) async -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256Hasher()
        let chunkSize = 4 * 1024 * 1024
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(chunk)
            await Task.yield()
        }
        return hasher.hexDigest()
    }

    // MARK: Internals

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.badResponse("not HTTP") }
        switch http.statusCode {
        case 200: return (data, http)
        case 401, 403: throw HubError.unauthorized
        case 404: throw HubError.repoNotFound(url.path)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw HubError.rateLimited(retryAfter: retryAfter)
        default: throw HubError.badResponse("HTTP \(http.statusCode)")
        }
    }

    private func decodeTreePage(_ data: Data) throws -> [HubFile] {
        struct RawFile: Decodable {
            struct LFS: Decodable {
                let oid: String?
                let size: Int64?
            }
            let path: String
            let size: Int64?
            let lfs: LFS?
            let oid: String?
        }
        let raw = try JSONDecoder().decode([RawFile].self, from: data)
        return raw.map { file in
            HubFile(
                path: file.path,
                sizeBytes: file.lfs?.size ?? file.size ?? 0,
                etag: file.lfs?.oid ?? file.oid ?? "",
                sha256: file.lfs?.oid)
        }
    }

    static func nextCursor(from response: HTTPURLResponse) -> String? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        // Format: <https://…?cursor=XYZ>; rel="next"
        guard let range = link.range(of: "cursor=([^&>]+)", options: .regularExpression) else { return nil }
        return String(link[range].dropFirst("cursor=".count))
    }

    private func matchesModelGlobs(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if path.contains("/") {
            // Nested files (e.g. `onnx/…`) are not needed for MLX inference.
            return false
        }
        let allowedExtensions = ["safetensors", "json", "txt", "jinja", "model", "tiktoken"]
        if allowedExtensions.contains((name as NSString).pathExtension.lowercased()) { return true }
        return name.hasPrefix("tokenizer") || name == "vocab"
    }
}

/// Removes the `Authorization` header when a request redirects away from the
/// Hub origin — signed CDN URLs don't need it and shouldn't see it.
///
/// Note: the completion-handler (non-async) delegate signature is deliberate —
/// the async variant trips a SILGen crash in Swift 6.3.2 when lowering the
/// ObjC thunk.
final class RedirectStrippingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        if url.host?.hasSuffix("huggingface.co") == true {
            completionHandler(request)
            return
        }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(stripped)
    }
}

/// Incremental SHA-256 wrapper over CryptoKit.
struct SHA256Hasher: Sendable {
    private var hasher = CryptoKit.SHA256()

    mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    func hexDigest() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}