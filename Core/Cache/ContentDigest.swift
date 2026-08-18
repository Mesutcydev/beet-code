import CryptoKit
import Foundation

/// Content-addressable identity helpers. Every derived-cache key in ForgeCache
/// is ultimately rooted in a SHA-256 over the bytes of a source of truth.
enum ContentDigest {

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    /// Hashes the file at url; nil when unreadable. The digest — never the
    /// path or mtime — is the correctness boundary for file-derived caches.
    static func fileDigest(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256Hex(data)
    }
}
