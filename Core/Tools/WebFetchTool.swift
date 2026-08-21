import Foundation

/// Bounded, approval-gated HTTP GET so the agent can read docs without
/// opening the in-app browser. `file://` / `javascript:` / `data:` are
/// rejected — this is not a workspace-escape hatch.
enum WebFetchError: Error, LocalizedError {
    case invalidURL(String)
    case blockedHost(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw): "Invalid or non-http(s) URL: \(raw)"
        case .blockedHost(let host): "Refusing to fetch private or loopback host: \(host)"
        }
    }
}

enum WebFetchPolicy {
    static func validatedURL(_ raw: String) throws -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.missingArgument("url") }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw WebFetchError.invalidURL(trimmed)
        }
        guard scheme == "http" || scheme == "https" else {
            throw WebFetchError.invalidURL(trimmed)
        }
        if let host = url.host, isBlockedHost(host) {
            throw WebFetchError.blockedHost(host)
        }
        return url
    }

    static func isBlockedHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower == "metadata.google.internal" {
            return true
        }
        if lower == "::1" || lower.hasPrefix("[::1]") { return true }
        let parts = lower.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 127 { return true }
            if parts[0] == 10 { return true }
            if parts[0] == 192 && parts[1] == 168 { return true }
            if parts[0] == 169 && parts[1] == 254 { return true }
            if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        }
        return false
    }
}

/// Best-effort visible-text extraction. Not a browser — just enough to turn
/// a docs HTML page into something a model can read.
enum HTMLText {
    static func extract(_ raw: String, limit: Int) -> String {
        var text = raw
        // Drop script/style blocks first so their contents never leak.
        for tag in ["script", "style", "noscript"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[\\s\\S]*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        let collapsed = text
            .replacingOccurrences(of: "[ \\t\\f\\r]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "\n…[truncated]"
    }
}

struct WebFetchTool: AgentTool {
    let name = "web_fetch"
    let summary = "Fetch a public http(s) URL and return its visible text (bounded)"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "url":{"type":"string","description":"http(s) URL to fetch"},
          "limit":{"type":"integer","description":"Max characters to return (default 12000, max 24000)"}
        },"required":["url"]}
        """

    static let defaultLimit = 12_000
    static let hardLimit = 24_000
    static let maxBytes = 256 * 1024

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let raw = call.string("url") else { return .none }
        return .command("web_fetch \(raw)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let raw = call.string("url") else { throw ToolError.missingArgument("url") }
        let url = try WebFetchPolicy.validatedURL(raw)
        let limit = min(max(call.int("limit") ?? Self.defaultLimit, 500), Self.hardLimit)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = ["User-Agent": "BeetCode/0.8 (agent web_fetch)"]
        let delegate = WebFetchRedirectGuard()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(from: url)
        } catch {
            return "error: fetch failed — \(error.localizedDescription)"
        }
        if let host = response.url?.host, WebFetchPolicy.isBlockedHost(host) {
            return "error: refused redirected host \(host)"
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            return "error: HTTP \(status) from \(url.absoluteString)"
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBytes {
                    return "error: response exceeded the \(Self.maxBytes) byte cap"
                }
            }
        } catch {
            return "error: fetch failed — \(error.localizedDescription)"
        }
        let rawText = String(decoding: data, as: UTF8.self)
        let type = (response.mimeType ?? "").lowercased()
        let body: String
        if type.contains("html") || rawText.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<!") {
            body = HTMLText.extract(rawText, limit: limit)
        } else {
            body = rawText.count > limit ? String(rawText.prefix(limit)) + "\n…[truncated]" : rawText
        }
        return "url: \(url.absoluteString)\nstatus: \(status)\n\n\(body)"
    }
}

/// Drops redirects onto loopback or RFC1918 hosts so web_fetch cannot be
/// used as an SSRF trampoline.
final class WebFetchRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, let host = url.host, !WebFetchPolicy.isBlockedHost(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
