import Foundation
import XCTest
@testable import BeetCode

final class AppleShipToolTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-ship-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDetectsGeneratedIOSProjectAndPlatform() throws {
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "platform: iOS\n".write(
            to: root.appendingPathComponent("project.yml"),
            atomically: true,
            encoding: .utf8)

        let container = try AppleShipTool.detectContainer(in: root)
        guard case .project(let detectedProject) = container else {
            return XCTFail("Expected an Xcode project")
        }
        XCTAssertEqual(detectedProject.lastPathComponent, project.lastPathComponent)
        XCTAssertEqual(
            AppleShipTool.detectPlatform(in: root, container: container),
            .ios)
    }

    func testWorkspaceWinsOverProjectAndMacOSIsDetected() throws {
        let workspace = root.appendingPathComponent("Example.xcworkspace", isDirectory: true)
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "platform: macOS\n".write(
            to: root.appendingPathComponent("project.yml"),
            atomically: true,
            encoding: .utf8)

        let container = try AppleShipTool.detectContainer(in: root)
        guard case .workspace(let detectedWorkspace) = container else {
            return XCTFail("Expected an Xcode workspace")
        }
        XCTAssertEqual(detectedWorkspace.lastPathComponent, workspace.lastPathComponent)
        XCTAssertEqual(
            AppleShipTool.detectPlatform(in: root, container: container),
            .macos)
    }

    func testReleaseNamesAreFilesystemSafe() {
        XCTAssertEqual(AppleShipTool.fileSafe("My Great/App"), "My-Great-App")
        XCTAssertEqual(AppleShipTool.fileSafe(""), "App")
    }

    func testUnsignedApprovalPreviewIsExplicit() throws {
        let call = try XCTUnwrap(ToolParser.parse(
            #"{"name":"apple_ship","arguments":{"platform":"ios"}}"#
        ).first)
        let context = ToolContext(workspace: Workspace(root: root))

        XCTAssertEqual(
            AppleShipTool().preview(call, in: context),
            .command("verify + archive . (ios, unsigned) → .beetcode/releases"))
    }

    func testParsesOnlyValidCodeSigningIdentities() {
        let output = """
          1) 1111111111111111111111111111111111111111 "Apple Development: Expired (AAAAAAAAAA)" (CSSMERR_TP_CERT_EXPIRED)
          2) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Example (TEAMID1234)"
             1 valid identities found
        """

        let identities = AppleDeliverySupport.parseSigningIdentities(output)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.fingerprint, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(identities.first?.teamID, "TEAMID1234")
    }

    func testParsesPhysicalDeviceAndConnectionState() throws {
        let data = try XCTUnwrap(#"{"result":{"devices":[{"identifier":"device-1","deviceProperties":{"name":"Test iPhone"},"hardwareProperties":{"marketingName":"iPhone 17","reality":"physical"},"connectionProperties":{"deviceAvailability":"available"}},{"identifier":"sim-1","deviceProperties":{"name":"Simulator"},"hardwareProperties":{"productType":"iPhone18,3","reality":"simulated"},"connectionProperties":{"deviceAvailability":"available"}}]}}"#.data(using: .utf8))

        let devices = AppleDeliverySupport.parseDevices(data)

        XCTAssertEqual(devices.count, 2)
        XCTAssertTrue(try XCTUnwrap(devices.first).isPhysical)
        XCTAssertTrue(try XCTUnwrap(devices.first).isConnected)
        XCTAssertFalse(try XCTUnwrap(devices.last).isPhysical)
    }

    func testGeneratedExportOptionsUseCurrentXcodeMethods() throws {
        let url = root.appendingPathComponent("ExportOptions.plist")
        try AppleShipTool.writeExportOptions(
            to: url,
            method: "debugging",
            identity: "ABC123",
            teamID: "TEAMID1234")

        let data = try Data(contentsOf: url)
        let options = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(options["method"] as? String, "debugging")
        XCTAssertNil(options["signingCertificate"])
        XCTAssertEqual(options["signingStyle"] as? String, "automatic")
        XCTAssertEqual(options["teamID"] as? String, "TEAMID1234")
    }

    func testGeneratedAppStoreOptionsCanUpload() throws {
        let url = root.appendingPathComponent("UploadOptions.plist")
        try AppleShipTool.writeExportOptions(
            to: url,
            method: "app-store-connect",
            identity: nil,
            teamID: "TEAMID1234",
            destination: "upload")

        let data = try Data(contentsOf: url)
        let options = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(options["method"] as? String, "app-store-connect")
        XCTAssertEqual(options["destination"] as? String, "upload")
    }

    func testGeneratedMacAppShipsEndToEnd() async throws {
        try CreateMacAppTool.writeScaffold(
            product: "ShipFixture",
            displayName: "Ship Fixture",
            bundleId: "com.beetcode.shipfixture",
            dest: root)
        let generate = try ShellRunner.runProcess(
            executable: try XCTUnwrap(CreateMacAppTool.xcodegenURL()).path,
            arguments: ["generate"],
            workingDirectory: root,
            timeout: 60)
        XCTAssertEqual(generate.exitCode, 0, generate.output)

        let call = try XCTUnwrap(ToolParser.parse(
            #"{"name":"apple_ship","arguments":{"platform":"macos","scheme":"ShipFixture","runTests":false}}"#
        ).first)
        let output = try await AppleShipTool().execute(
            call,
            in: ToolContext(workspace: Workspace(root: root)))

        XCTAssertTrue(output.contains("Ship Center: ready"), output)
        let releases = root.appendingPathComponent(".beetcode/releases", isDirectory: true)
        let release = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: releases,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]).first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: release.appendingPathComponent("ShipFixture-macos.zip").path))
        let report = try String(
            contentsOf: release.appendingPathComponent("Ship-Report.md"),
            encoding: .utf8)
        XCTAssertTrue(report.contains("Release archive: **Passed**"), report)
        XCTAssertTrue(report.contains("Package: **Passed**"), report)
    }
}
