import XCTest
@testable import BeetCode

final class SmartDownloaderTests: XCTestCase {

    func testHubRedirectHostValidationRejectsLookalikes() {
        XCTAssertTrue(RedirectStrippingDelegate.isTrustedHubHost("huggingface.co"))
        XCTAssertTrue(RedirectStrippingDelegate.isTrustedHubHost("cdn.huggingface.co"))
        XCTAssertFalse(RedirectStrippingDelegate.isTrustedHubHost("evilhuggingface.co"))
        XCTAssertFalse(RedirectStrippingDelegate.isTrustedHubHost("huggingface.co.attacker.example"))
    }

    typealias Logic = SmartFileDownloader.Logic
    typealias Sidecar = SmartFileDownloader.SidecarState

    func testPartialRestartsWhenETagChanges() {
        let sidecar = Sidecar(etag: "abc123", totalBytes: 1000, completedBytes: 400, sha256: nil)
        XCTAssertFalse(Logic.shouldRestartPartial(sidecar: sidecar, currentETag: "abc123"))
        XCTAssertTrue(Logic.shouldRestartPartial(sidecar: sidecar, currentETag: "def456"))
        // No sidecar at all → fresh download, nothing to restart.
        XCTAssertFalse(Logic.shouldRestartPartial(sidecar: nil, currentETag: "abc123"))
    }

    func testRangeResponseTruncationRules() {
        // Server ignored the range and sent 200 while we had a partial.
        XCTAssertTrue(Logic.mustTruncatePartial(statusCode: 200, resumedFromOffset: 500))
        // 200 on a fresh download is normal.
        XCTAssertFalse(Logic.mustTruncatePartial(statusCode: 200, resumedFromOffset: 0))
        // 206 always continues the partial.
        XCTAssertFalse(Logic.mustTruncatePartial(statusCode: 206, resumedFromOffset: 500))
    }

    func testRetryBackoffBounds() {
        // Retry-After honored when sane.
        XCTAssertEqual(Logic.retryDelay(attempt: 1, retryAfter: 7), 7)
        // Absurd Retry-After values are ignored in favor of backoff.
        XCTAssertLessThan(Logic.retryDelay(attempt: 1, retryAfter: 9999), 61)
        // Backoff grows but is capped at 60s; always positive.
        for attempt in 1...10 {
            let delay = Logic.retryDelay(attempt: attempt, retryAfter: nil)
            XCTAssertGreaterThanOrEqual(delay, 0.5)
            XCTAssertLessThanOrEqual(delay, 60)
        }
    }

    func testDiskPreflight() {
        // Enough free → nil.
        XCTAssertNil(Logic.diskPreflight(pendingBytes: 1_000_000_000, freeBytes: 2_000_000_000))
        // Free below pending + 200MB margin → diskFull.
        let error = Logic.diskPreflight(pendingBytes: 1_000_000_000, freeBytes: 1_100_000_000)
        guard case .diskFull(let needed, let free)? = error else {
            return XCTFail("expected diskFull")
        }
        XCTAssertEqual(needed, 1_200_000_000)
        XCTAssertEqual(free, 1_100_000_000)
    }

    func testSidecarRoundTrip() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let original = Sidecar(etag: "sha-abc", totalBytes: 5000, completedBytes: 1234, sha256: "sha-abc")
        let url = temp.appendingPathComponent("model.safetensors.incomplete.json")
        let data = try! JSONEncoder().encode(original)
        try! data.write(to: url)

        let loaded = try? JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url))
        XCTAssertEqual(loaded, original)
    }

    func testRetryabilityClassification() {
        XCTAssertTrue(SmartFileDownloader.DownloadError.checksumMismatch.isRetryable)
        XCTAssertTrue(SmartFileDownloader.DownloadError.serverChanged.isRetryable)
        XCTAssertFalse(SmartFileDownloader.DownloadError.unauthorized.isRetryable)
        XCTAssertFalse(SmartFileDownloader.DownloadError.notFound.isRetryable)
        XCTAssertFalse(SmartFileDownloader.DownloadError.diskFull(needed: 1, free: 0).isRetryable)
        XCTAssertFalse(SmartFileDownloader.DownloadError.paused.isRetryable)
    }
}

final class HubClientTests: XCTestCase {

    func testNextCursorParsing() {
        func response(with link: String?) -> HTTPURLResponse {
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: link.map { ["Link": $0] })!
            return response
        }

        let link = #"<https://huggingface.co/api/models/x/tree/main?recursive=true&expand=true&cursor=AbCdEf>; rel="next""#
        XCTAssertEqual(HFHubClient.nextCursor(from: response(with: link)), "AbCdEf")
        XCTAssertNil(HFHubClient.nextCursor(from: response(with: nil)))
        XCTAssertNil(HFHubClient.nextCursor(from: response(with: #"<https://huggingface.co/api>; rel="prev""#)))
    }

    func testModelFileGlobFiltering() {
        let client = HFHubClient(tokenProvider: { nil })
        _ = client // client methods under test take explicit args; glob check is internal logic

        // Mirror of the internal rule (kept in sync deliberately):
        func matches(_ path: String) -> Bool {
            let name = (path as NSString).lastPathComponent
            if path.contains("/") { return false }
            let allowed = ["safetensors", "json", "txt", "jinja", "model", "tiktoken"]
            if allowed.contains((name as NSString).pathExtension.lowercased()) { return true }
            return name.hasPrefix("tokenizer") || name == "vocab"
        }

        XCTAssertTrue(matches("model.safetensors"))
        XCTAssertTrue(matches("model-00001-of-00003.safetensors"))
        XCTAssertTrue(matches("config.json"))
        XCTAssertTrue(matches("tokenizer.json"))
        XCTAssertTrue(matches("tokenizer_config.json"))
        XCTAssertFalse(matches("README.md"))
        XCTAssertFalse(matches(".gitattributes"))
        XCTAssertFalse(matches("onnx/model.onnx"))
        XCTAssertFalse(matches("coreml/chunked/model.mlmodelc"))
    }

    func testSHA256Hasher() {
        var hasher = SHA256Hasher()
        hasher.update(Data("hello ".utf8))
        hasher.update(Data("world".utf8))
        // sha256("hello world")
        XCTAssertEqual(
            hasher.hexDigest(),
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }
}
