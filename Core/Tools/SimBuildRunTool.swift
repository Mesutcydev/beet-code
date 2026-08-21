import Foundation

/// P1.1: the build → install → launch → screenshot → inspect loop as ONE
/// approval-gated tool. The agent can iterate: run it, read the returned
/// diagnostics + screenshot description, fix, and run again.
struct SimBuildRunTool: AgentTool {
    let name = "sim_build_run"
    let summary = "Build the project for the iOS Simulator, install, launch, screenshot, and describe the result"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "project":{"type":"string","description":"Project directory (default: workspace root; auto-detects .xcodeproj or Package.swift)"},
          "scheme":{"type":"string","description":"Xcode scheme (optional; auto-detected)"},
          "udid":{"type":"string","description":"Simulator UDID (optional; a booted device is reused, else the first iPhone is booted)"},
          "bundleId":{"type":"string","description":"Bundle identifier to launch (optional; read from the built app)"}
        },"required":[]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let project = call.string("project") ?? "."
        return .command("xcodebuild + simctl build-run-inspect for \(project)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let workspace = context.workspace

        // 1. Project directory (workspace-validated).
        let projectDir: URL
        if let project = call.string("project") {
            projectDir = try workspace.resolve(project, access: .read).url
        } else {
            projectDir = workspace.root
        }

        try MacBuildRunTool.generateProjectIfNeeded(in: projectDir)

        // 2. Detect the project file / scheme.
        let projectFile = try Self.detectProject(in: projectDir)
        let scheme = call.string("scheme") ?? Self.detectScheme(projectFile, in: projectDir)

        // 3. Pick a simulator (reuse booted, else boot the first iPhone).
        let udid = try await Self.resolveSimulator(preferred: call.string("udid"))

        // 4. Build into a workspace-local DerivedData.
        let derivedData = workspace.root.appendingPathComponent(".beetcode/DerivedData", isDirectory: true)
        try? FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        let buildArgs = Self.buildArguments(
            projectFile: projectFile,
            scheme: scheme,
            derivedData: derivedData)
        let build = try ShellRunner.runProcess(
            executable: "/usr/bin/xcodebuild",
            arguments: buildArgs,
            workingDirectory: projectDir,
            timeout: 600)
        guard !build.timedOut else {
            return "error: build timed out after 600s\n" + RunCommandTool.truncate(build.output)
        }
        guard build.exitCode == 0 else {
            let diagnostics = DiagnosticParser.parse(build.output)
            return DiagnosticParser.render(diagnostics)
                + "\n\nraw output:\n" + RunCommandTool.truncate(build.output, limit: 8_000)
        }

        // 5. Locate the built .app.
        guard let appURL = Self.findBuiltApp(in: derivedData) else {
            return "error: build succeeded but no .app found in \(derivedData.path)"
        }
        let bundleID = call.string("bundleId") ?? SimctlRunner.bundleIdentifier(of: appURL)

        // 6. Install + launch.
        let install = await SimctlRunner.run(["install", udid, appURL.path])
        guard !install.contains("error") else { return "error: install failed: \(install)" }
        var launchLog = ""
        if let bundleID {
            launchLog = await SimctlRunner.run(["launch", udid, bundleID])
        }

        // 7. Screenshot.
        let shotsDir = workspace.root.appendingPathComponent(".beetcode/screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        let shotURL = shotsDir.appendingPathComponent("sim-\(Int(Date().timeIntervalSince1970)).png")
        _ = await SimctlRunner.run(["io", udid, "screenshot", shotURL.path])

        // 8. Inspect via the vision provider when available.
        var inspection = "(no vision provider configured — attach the screenshot manually or use describe_image)"
        if await VisionProvider.isAvailable, let data = try? Data(contentsOf: shotURL), data.count > 0 {
            if let description = try? await VisionProvider.describe(
                imageAt: shotURL,
                prompt: "Describe this iOS app screen concisely: what is visible, what state is it in, any errors on screen?") {
                inspection = description
            }
        }

        return """
        Build: succeeded (\(scheme))
        App: \(appURL.lastPathComponent) (\(bundleID ?? "unknown bundle id"))
        Launch: \(launchLog.isEmpty ? "ok" : launchLog)
        Screenshot: \(shotURL.path)
        Screen inspection: \(inspection)
        """
    }

    // MARK: Helpers

    private static func detectProject(in dir: URL) throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return dir.appendingPathComponent(xcodeproj)
        }
        if contents.contains("Package.swift") {
            return dir.appendingPathComponent("Package.swift")
        }
        throw ToolError.missingArgument("project — no .xcodeproj or Package.swift found in \(dir.path)")
    }

    private static func detectScheme(_ projectFile: URL, in dir: URL) -> String {
        if projectFile.pathExtension == "xcodeproj" {
            return projectFile.deletingPathExtension().lastPathComponent
        }
        return ""
    }

    private static func buildArguments(projectFile: URL, scheme: String, derivedData: URL) -> [String] {
        if projectFile.pathExtension == "xcodeproj" {
            return [
                "-project", projectFile.path,
                "-scheme", scheme,
                "-sdk", "iphonesimulator",
                "-destination", "generic/platform=iOS Simulator",
                "-derivedDataPath", derivedData.path,
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ]
        }
        // Swift Package: build with the iOS simulator SDK.
        return ["build", "-c", "debug"]
    }

    private static func findBuiltApp(in derivedData: URL) -> URL? {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: products, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "app" {
            return url
        }
        return nil
    }

    /// Picks the preferred UDID, else a booted iPhone, else boots the first
    /// iPhone device. All via the off-main, time-bounded SimctlRunner.
    private static func resolveSimulator(preferred: String?) async throws -> String {
        if let preferred, !preferred.isEmpty { return preferred }
        let list = await SimctlRunner.run(["list", "devices", "-j"])
        guard let data = list.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]]
        else { throw ToolError.missingArgument("udid — cannot list simulators") }
        var booted: String?
        var firstiPhone: String?
        for (_, entries) in runtimes.sorted(by: { $0.key < $1.key }) {
            for entry in entries {
                guard let udid = entry["udid"] as? String,
                      let name = entry["name"] as? String,
                      let state = entry["state"] as? String
                else { continue }
                if name.hasPrefix("iPhone") {
                    if firstiPhone == nil { firstiPhone = udid }
                    if state.contains("Booted") { booted = udid }
                }
            }
        }
        guard let target = booted ?? firstiPhone else {
            throw ToolError.missingArgument("udid — no iPhone simulator available")
        }
        if booted == nil {
            _ = await SimctlRunner.run(["boot", target], timeout: SimctlRunner.bootTimeout)
        }
        return target
    }
}