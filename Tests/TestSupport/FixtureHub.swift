import Foundation
@testable import BeetCode

/// Serves model downloads from a local fixture directory instead of the HF
/// hub. File URL requests through URLSession return status 200 with the
/// whole file — SmartFileDownloader's 200-handling truncates stale partials,
/// which also exercises that path.
final class FixtureHub: HubServing, @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var requestLog: [String] = []

    init(directory: URL) {
        self.directory = directory
    }

    var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestLog
    }

    func listModelFiles(repo: String, revision: String) async throws -> [HubFile] {
        var files: [HubFile] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return [] }
        let urls = (enumerator.allObjects as? [URL]) ?? []
        // The enumerator may hand back /private/var/… while the root is
        // /var/… — canonicalize both sides before computing relatives.
        let canonicalRoot = Workspace.resolvingSymlinks(directory).path
        for url in urls {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            let canonical = Workspace.resolvingSymlinks(url).path
            let relative: String
            if canonical.hasPrefix(canonicalRoot + "/") {
                relative = String(canonical.dropFirst(canonicalRoot.count + 1))
            } else {
                relative = url.lastPathComponent
            }
            files.append(
                HubFile(
                    path: relative,
                    sizeBytes: Int64(size),
                    etag: "\"fixture-\(relative)\"",
                    sha256: await HFHubClient.sha256Hex(ofFile: url)))
        }
        return files
    }

    func resolveURL(repo: String, path: String, revision: String) -> URL {
        directory.appendingPathComponent(path)
    }

    func downloadRequest(url: URL, offset: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        lock.lock()
        requestLog.append(url.lastPathComponent)
        lock.unlock()
        return request
    }

    func response(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        // File URLs come back as plain NSURLResponse from URLSession;
        // synthesize the HTTP envelope the downloader expects (status 200 —
        // which also exercises the stale-partial truncation path on resume).
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(size)"])
        else { throw URLError(.badServerResponse) }
        return (bytes, http)
    }
}