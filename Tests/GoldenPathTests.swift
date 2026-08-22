import Foundation
import XCTest
@testable import BeetCode

/// Golden path: open an Apple project, build for the simulator, screenshot.
/// Planning helpers are hermetic. The full scaffold → sim_build_run loop is
/// opt-in via `BEETCODE_LIVE_SMOKE=1` (same flag as LiveSmokeTests) so CI
/// never boots a simulator or runs xcodebuild.
final class GoldenPathTests: XCTestCase {

    func testDetectsXcodeprojAndScheme() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Demo.xcodeproj"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try SimBuildRunTool.detectProject(in: root)
        XCTAssertEqual(project.lastPathComponent, "Demo.xcodeproj")
        XCTAssertEqual(SimBuildRunTool.detectScheme(project, in: root), "Demo")
    }

    func testDetectsSwiftPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-golden-spm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try SimBuildRunTool.detectProject(in: root)
        XCTAssertEqual(project.lastPathComponent, "Package.swift")
    }

    func testDetectProjectFailsWithoutAnAppleProject() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-golden-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try SimBuildRunTool.detectProject(in: root))
    }

    func testSimulatorBuildArgumentsDisableSigning() {
        let project = URL(fileURLWithPath: "/tmp/Demo.xcodeproj")
        let derived = URL(fileURLWithPath: "/tmp/DerivedData")
        let args = SimBuildRunTool.buildArguments(
            projectFile: project, scheme: "Demo", derivedData: derived)
        XCTAssertTrue(args.contains("-sdk"))
        XCTAssertTrue(args.contains("iphonesimulator"))
        XCTAssertTrue(args.contains("CODE_SIGNING_ALLOWED=NO"))
        XCTAssertTrue(args.contains("build"))
        XCTAssertEqual(args.last, "build")
    }

    func testFindBuiltAppWalksDerivedData() throws {
        let derived = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-golden-app-\(UUID().uuidString)", isDirectory: true)
        let app = derived
            .appendingPathComponent("Build/Products/Debug-iphonesimulator/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: derived) }

        XCTAssertEqual(SimBuildRunTool.findBuiltApp(in: derived)?.lastPathComponent, "Demo.app")
    }

    @MainActor
    func testDefaultCodingToolsIncludeSimulatorLoop() {
        let names = Set(AgentSessionController.defaultTools.map(\.name))
        XCTAssertTrue(names.contains("sim_build_run"))
        XCTAssertTrue(names.contains("create_ios_app"))
        XCTAssertFalse(names.contains("computer_click"))
    }

    func testScaffoldBuildSimScreenshotLoop() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("live smoke is opt-in (BEETCODE_LIVE_SMOKE=1)")
        }
        guard CreateMacAppTool.xcodegenURL() != nil else {
            throw XCTSkip("xcodegen is required for the live iOS scaffold")
        }

        do {
            _ = try await SimBuildRunTool.resolveSimulator(preferred: nil)
        } catch {
            throw XCTSkip("no iPhone simulator available: \(error)")
        }

        let workspace = TempWorkspace()
        let context = ToolContext(workspace: workspace.workspace)
        let createCall = ParsedToolCall(
            name: "create_ios_app",
            arguments: .object(["name": .string("GoldenSmoke")]),
            index: 0)
        let scaffold = try await CreateIOSAppTool().execute(createCall, in: context)
        XCTAssertTrue(scaffold.contains("Created GoldenSmoke"), scaffold)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.url.appendingPathComponent("GoldenSmoke.xcodeproj").path)
                || scaffold.contains("xcodegen generate: ok"),
            scaffold)

        let runCall = ParsedToolCall(
            name: "sim_build_run",
            arguments: .object([:]),
            index: 1)
        let result = try await SimBuildRunTool().execute(runCall, in: context)
        XCTAssertTrue(result.contains("Build: succeeded"), result)
        XCTAssertTrue(result.contains("Screenshot:"), result)

        let screenshotLine = result.split(separator: "\n").first { $0.hasPrefix("Screenshot:") }
        let path = screenshotLine.map { String($0.dropFirst("Screenshot:".count)).trimmingCharacters(in: .whitespaces) }
        if let path {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "screenshot missing at \(path)")
        }
    }
}
