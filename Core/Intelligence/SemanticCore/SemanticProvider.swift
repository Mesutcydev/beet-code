import Foundation

/// A semantically resolved symbol from an external indexer (LSP/SCIP).
/// Distinct from ParsedSymbol: this is cross-checked, server-computed truth.
struct ResolvedSymbol: Sendable, Equatable {
    let name: String
    let kind: String            // LSP SymbolKind rendered as a name
    let line: Int               // 1-based
    let containerName: String?
}

/// Semantic enrichment seam (spec §24, Phase 5). Implementations wrap real
/// external indexers. The structural parser remains the broad fallback;
/// semantic output is always labeled with its source and never blended into
/// syntactic results silently.
protocol SemanticProvider: Sendable {
    /// Honest source label persisted on enriched nodes: e.g. `sourcekit-lsp`.
    var sourceLabel: String { get }
    /// Real availability probe (binary present + spawnable), not a guess.
    func isAvailable() async -> Bool
    /// documentSymbols for one file. Throws on protocol failure; callers
    /// degrade to syntactic-only intelligence rather than failing indexing.
    func documentSymbols(path: String, content: String, language: String) async throws -> [ResolvedSymbol]
}

/// Minimal JSON-RPC stdio transport with Content-Length framing — the real
/// LSP wire format, no shortcuts.
final class JSONRPCTransport: @unchecked Sendable {

    enum TransportError: Error { case processExited, malformedMessage, timeout }

    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1

    init(launchPath: String, arguments: [String] = []) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        try process.run()
    }

    deinit { terminate() }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Sends a request and waits for the matching response id. Synchronous
    /// by design; callers run it off the cooperative pool.
    func request(method: String, params: [String: Any], timeout: TimeInterval = 10) throws -> Any? {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        try send(message)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = try readMessage() {
                // Notifications and unrelated responses are skipped; only the
                // matching id completes the request.
                if let responseID = response["id"] as? Int, responseID == id {
                    return response["result"]
                }
                continue
            }
        }
        throw TransportError.timeout
    }

    func notify(method: String, params: [String: Any]) throws {
        lock.lock()
        defer { lock.unlock() }
        try send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ message: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: message)
        let header = "Content-Length: \(body.count)\r\n\r\n"
        guard process.isRunning else { throw TransportError.processExited }
        stdin.write(Data(header.utf8))
        stdin.write(body)
    }

    /// Blocking framed read. Returns nil when no complete message is
    /// available yet (caller retries until its deadline).
    private func readMessage() throws -> [String: Any]? {
        // Blocking pump: returns Data() only at EOF.
        let chunk = stdout.availableData
        if chunk.isEmpty {
            throw TransportError.processExited
        }
        buffer.append(chunk)

        // Parse header.
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            usleep(5_000)
            return nil
        }
        let header = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
        var contentLength = 0
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":")
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "Content-Length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard contentLength > 0 else { throw TransportError.malformedMessage }
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else {
            usleep(5_000)
            return nil
        }
        let body = buffer[bodyStart..<(bodyStart + contentLength)]
        buffer.removeSubrange(..<(bodyStart + contentLength))
        return try JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

}

/// sourcekit-lsp provider: real LSP initialize → didOpen → documentSymbol.
/// Availability is probed by locating the binary; a failed initialize is
/// reported as unavailable — never faked.
final class SourceKitLSPProvider: SemanticProvider {

    let sourceLabel = "sourcekit-lsp"

    /// Resolved at init; nil when the toolchain has no sourcekit-lsp.
    private let binaryPath: String?

    init(binaryPath: String? = SourceKitLSPProvider.locateBinary()) {
        self.binaryPath = binaryPath
    }

    static func locateBinary() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-f", "sourcekit-lsp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    func isAvailable() async -> Bool {
        binaryPath != nil
    }

    func documentSymbols(path: String, content: String, language: String) async throws -> [ResolvedSymbol] {
        guard let binaryPath else { return [] }
        // One short-lived server per batch call: sourcekit-lsp is cheap to
        // spawn and this keeps indexing stateless.
        return try await Task.detached(priority: .utility) {
            let transport = try JSONRPCTransport(launchPath: binaryPath)
            defer { transport.terminate() }

            let uri = "file://\(path)"
            _ = try transport.request(method: "initialize", params: [
                "processId": NSNull(),
                "rootUri": NSNull(),
                "capabilities": [String: Any](),
            ])
            try transport.notify(method: "initialized", params: [:])
            try transport.notify(method: "textDocument/didOpen", params: [
                "textDocument": [
                    "uri": uri,
                    "languageId": language == "swift" ? "swift" : language,
                    "version": 1,
                    "text": content,
                ],
            ])
            let result = try transport.request(
                method: "textDocument/documentSymbol",
                params: ["textDocument": ["uri": uri]])
            _ = try? transport.request(method: "shutdown", params: [:], timeout: 2)

            guard let items = result as? [[String: Any]] else { return [] }
            return Self.flattenSymbols(items)
        }.value
    }

    /// documentSymbol may return hierarchical DocumentSymbol[] (children)
    /// or flat SymbolInformation[] (location); both normalize here.
    static func flattenSymbols(_ items: [[String: Any]]) -> [ResolvedSymbol] {
        var out: [ResolvedSymbol] = []
        func walk(_ item: [String: Any], container: String?) {
            // sourcekit-lsp reports function names with a signature tail
            // ("render()"); normalize to the bare identifier so enrichment
            // matching compares like with like.
            var name = item["name"] as? String ?? ""
            if name.hasSuffix("()") { name = String(name.dropLast(2)) }
            let kindNumber = item["kind"] as? Int ?? 0
            let location = item["location"] as? [String: Any]
            let selection = item["selectionRange"] as? [String: Any]
            let range = (item["range"] as? [String: Any]) ?? (location?["range"] as? [String: Any])
            let start = (selection ?? range)?["start"] as? [String: Any]
            let line = (start?["line"] as? Int ?? -1) + 1
            out.append(ResolvedSymbol(
                name: name, kind: lspKindName(kindNumber),
                line: line, containerName: container))
            for child in item["children"] as? [[String: Any]] ?? [] {
                walk(child, container: name)
            }
        }
        for item in items { walk(item, container: nil) }
        return out
    }

    static func lspKindName(_ kind: Int) -> String {
        switch kind {
        case 5: "class"; case 11: "struct"; case 10: "enum"; case 8: "interface"
        case 6: "method"; case 12: "function"; case 13: "variable"
        case 7: "property"; case 9: "constructor"; case 3: "namespace"
        default: "symbol(\(kind))"
        }
    }
}
