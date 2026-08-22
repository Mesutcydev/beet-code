import Foundation

enum AppIdentity {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var userAgent: String {
        "BeetCode/\(version) (macOS coding agent)"
    }

    static var browserUserAgent: String {
        "BeetCode/\(version) (agent-controlled browser)"
    }
}
