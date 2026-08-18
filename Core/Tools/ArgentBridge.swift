import Foundation

/// Bridges BeetCode to the argent CLI (`argent run <tool> --args <json>`),
/// which exposes iOS-simulator (and Android/Chromium) device interaction:
/// boot, launch, tap, swipe, type, describe, screenshot. When argent is not
/// installed the tools fail with a clear message instead of crashing.
enum ArgentBridge {

    private static let candidates = [
        "/Users/\(NSUserName())/.local/bin/argent",
        "/opt/homebrew/bin/argent",
        "/usr/local/bin/argent",
        "/usr/bin/argent",
    ]

    static var executableURL: URL? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Last resort: resolve from PATH.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "argent"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static var isAvailable: Bool { executableURL != nil }

    enum ArgentError: Error, LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "argent is not installed — install it (npm i -g @swmansion/argent) to let the agent drive the iOS simulator. The built-in panel still works for boot/install/launch/screenshots."
            case .failed(let output):
                return "argent failed: \(String(output.prefix(500)))"
            }
        }
    }

    /// Runs an argent tool with a JSON payload and returns its raw output.
    static func run(
        _ tool: String,
        args: [String: Any],
        outputPath: String? = nil,
        timeout: TimeInterval = 120
    ) throws -> String {
        guard let executable = executableURL else { throw ArgentError.unavailable }

        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: args)
        } catch {
            throw ArgentError.failed("cannot encode arguments: \(error)")
        }

        var arguments = ["run", tool, "--args", String(data: payload, encoding: .utf8) ?? "{}", "--json"]
        if let outputPath {
            arguments += ["--out", outputPath]
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ShellRunner.sanitizedEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ArgentError.failed(error.localizedDescription)
        }

        // Read with a hard deadline: a hung argent tool must never block the
        // agent. The whole process tree is killed on expiry.
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let handle = pipe.fileHandleForReading
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        var status: Int32 = 0
        let reaped = waitpid(process.processIdentifier, &status, WNOHANG)
        if reaped != process.processIdentifier {
            kill(process.processIdentifier, SIGKILL)
            _ = waitpid(process.processIdentifier, &status, 0)
            throw ArgentError.failed("argent \(tool) timed out after \(Int(timeout))s")
        }
        let output = String(decoding: data, as: UTF8.self)
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 1
        guard exitCode == 0 else {
            throw ArgentError.failed(output.isEmpty ? "exit \(process.terminationStatus)" : output)
        }
        return output
    }
}