import Foundation

/// Runs `xcrun simctl` subprocesses OFF the main actor with a hard timeout.
/// Every call hops to a detached task; the main thread is never blocked by
/// device listing, booting, or screenshot capture.
///
/// Lives in Core (not App) because agent tools (SimBuildRunTool) drive it and
/// the CLI target must compile without the UI layer.
enum SimctlRunner {

    static let defaultTimeout: TimeInterval = 60
    static let bootTimeout: TimeInterval = 300

    static func run(
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        maxOutputBytes: Int = 8 * 1024 * 1024
    ) async -> String {
        await Task.detached(priority: .utility) {
            guard let result = try? ShellRunner.runProcess(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl"] + arguments,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes)
            else { return "xcrun simctl unavailable" }
            return result.timedOut ? "simctl timed out after \(Int(timeout))s" : result.output
        }.value
    }

    /// Reads the bundle identifier from an app bundle's Info.plist.
    /// Pure Foundation — safe to call from Core agent tools.
    static func bundleIdentifier(of appBundle: URL) -> String? {
        let plistURL = appBundle.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
              as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String
        else { return nil }
        return identifier
    }
}
