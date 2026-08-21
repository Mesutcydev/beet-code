import Foundation

/// Build a macOS app and launch it. Pair with `create_macos_app` so an agent
/// can go from empty folder → running window without inventing xcodebuild.
struct MacBuildRunTool: AgentTool {
    let name = "macos_build_run"
    let summary = "Build the macOS app and launch the resulting .app"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "project":{"type":"string","description":"Project directory (default: workspace root)"},
          "scheme":{"type":"string","description":"Xcode scheme (optional; auto-detected)"}
        },"required":[]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let project = call.string("project") ?? "."
        return .command("xcodebuild + open for \(project) (macOS)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let workspace = context.workspace
        let projectDir: URL
        if let project = call.string("project") {
            projectDir = try workspace.resolve(project, access: .read).url
        } else {
            projectDir = workspace.root
        }

        try Self.generateProjectIfNeeded(in: projectDir)

        let projectFile = try Self.detectProject(in: projectDir)
        let scheme = call.string("scheme") ?? Self.detectScheme(projectFile)

        let derivedData = workspace.root.appendingPathComponent(".beetcode/DerivedData", isDirectory: true)
        try? FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        let build = try ShellRunner.runProcess(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-project", projectFile.path,
                "-scheme", scheme,
                "-destination", "platform=macOS",
                "-derivedDataPath", derivedData.path,
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
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

        guard let appURL = Self.findBuiltApp(in: derivedData) else {
            return "error: build succeeded but no .app found in \(derivedData.path)"
        }

        let launch = try ShellRunner.runProcess(
            executable: "/usr/bin/open",
            arguments: ["-n", appURL.path],
            workingDirectory: projectDir,
            timeout: 15)
        if launch.exitCode != 0 {
            return "Build: succeeded (\(scheme))\nApp: \(appURL.path)\nLaunch failed: \(launch.output)"
        }
        return """
        Build: succeeded (\(scheme))
        App: \(appURL.path)
        Launch: opened
        The macOS app is running. Use computer_ui_tree / computer_screenshot if you need to verify the window.
        """
    }

    static func generateProjectIfNeeded(in dir: URL) throws {
        let yml = dir.appendingPathComponent("project.yml")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasXcodeproj = contents.contains(where: { $0.hasSuffix(".xcodeproj") })
        guard FileManager.default.fileExists(atPath: yml.path), !hasXcodeproj,
              let xcodegen = CreateMacAppTool.xcodegenURL()
        else { return }
        _ = try ShellRunner.runProcess(
            executable: xcodegen.path,
            arguments: ["generate"],
            workingDirectory: dir,
            timeout: 60)
    }

    private static func detectProject(in dir: URL) throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return dir.appendingPathComponent(xcodeproj)
        }
        throw ToolError.missingArgument("project — no .xcodeproj found in \(dir.path). Run create_macos_app or xcodegen generate.")
    }

    private static func detectScheme(_ projectFile: URL) -> String {
        projectFile.deletingPathExtension().lastPathComponent
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
}
