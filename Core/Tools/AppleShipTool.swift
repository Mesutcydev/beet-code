import Foundation

/// Produces a reviewable release bundle for a native iOS or macOS app.
///
/// The tool deliberately defaults to unsigned archives. Signing and IPA
/// export are opt-in because they can use developer credentials and
/// provisioning profiles installed on the Mac.
struct AppleShipTool: AgentTool {
    enum Platform: String, Sendable {
        case ios
        case macos

        var displayName: String { self == .ios ? "iOS" : "macOS" }
        var archiveDestination: String {
            self == .ios ? "generic/platform=iOS" : "generic/platform=macOS"
        }
        var verificationDestination: String {
            self == .ios ? "generic/platform=iOS Simulator" : "platform=macOS"
        }
    }

    enum Container: Sendable, Equatable {
        case workspace(URL)
        case project(URL)

        var url: URL {
            switch self {
            case .workspace(let url), .project(let url): url
            }
        }

        var xcodebuildArguments: [String] {
            switch self {
            case .workspace(let url): ["-workspace", url.path]
            case .project(let url): ["-project", url.path]
            }
        }
    }

    let name = "apple_ship"
    let summary = "Verify and package a macOS or iOS release with logs and a delivery report"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "project":{"type":"string","description":"Project directory (default: workspace root)"},
          "platform":{"type":"string","enum":["auto","ios","macos"],"description":"Apple platform (default: auto-detect)"},
          "scheme":{"type":"string","description":"Xcode scheme (optional; defaults to the project name)"},
          "configuration":{"type":"string","description":"Build configuration (default: Release)"},
          "runTests":{"type":"boolean","description":"Run tests when test sources exist, otherwise perform a verification build (default: true)"},
          "allowSigning":{"type":"boolean","description":"Allow Xcode to use installed signing credentials (default: false)"},
          "signingIdentity":{"type":"string","description":"Optional Keychain code-signing identity SHA-1 fingerprint or exact name"},
          "developmentTeam":{"type":"string","description":"Optional Apple Developer Team ID"},
          "provisioningProfile":{"type":"string","description":"Optional installed provisioning profile name or UUID"},
          "allowProvisioningUpdates":{"type":"boolean","description":"Allow Xcode to manage signing assets for the selected developer account (default: false)"},
          "exportMethod":{"type":"string","enum":["debugging","release-testing","app-store-connect","enterprise"],"description":"Signed iOS export method (default: debugging)"},
          "uploadToAppStoreConnect":{"type":"boolean","description":"Upload the signed archive through Xcode. Requires app-store-connect export and no device install."},
          "exportOptionsPlist":{"type":"string","description":"Optional workspace-relative ExportOptions.plist override. Requires allowSigning=true."},
          "installDevice":{"type":"string","description":"Connected physical device identifier, or auto. Requires a signed iOS export."}
        },"required":[]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let project = call.string("project") ?? "."
        let platform = call.string("platform") ?? "auto"
        let signing = call.bool("allowSigning") == true ? ", signing enabled" : ", unsigned"
        let install = call.string("installDevice")?.nilIfEmpty == nil ? "" : ", then install"
        return .command("verify + archive \(project) (\(platform)\(signing)\(install)) → .beetcode/releases")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let projectDirectory = try Self.projectDirectory(call.string("project"), in: context.workspace)
        try MacBuildRunTool.generateProjectIfNeeded(in: projectDirectory)

        let container = try Self.detectContainer(in: projectDirectory)
        let platform = try Self.resolvePlatform(call.string("platform"), in: projectDirectory, container: container)
        let scheme = call.string("scheme")?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? container.url.deletingPathExtension().lastPathComponent
        let configuration = call.string("configuration")?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Release"
        let shouldVerify = call.bool("runTests") ?? true
        let allowSigning = call.bool("allowSigning") ?? false
        let signingIdentity = call.string("signingIdentity")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let developmentTeam = call.string("developmentTeam")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let provisioningProfile = call.string("provisioningProfile")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let allowProvisioningUpdates = call.bool("allowProvisioningUpdates") ?? false
        let exportMethod = try Self.exportMethod(call.string("exportMethod"))
        let uploadToAppStoreConnect = call.bool("uploadToAppStoreConnect") ?? false
        let installDevice = call.string("installDevice")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if !allowSigning,
           signingIdentity != nil || developmentTeam != nil || provisioningProfile != nil
                || installDevice != nil || call.string("exportMethod") != nil {
            return "error: signing identity, team, profile, export method, and device install require allowSigning=true"
        }
        if installDevice != nil, platform != .ios {
            return "error: installDevice is only supported for signed iOS and iPadOS builds"
        }
        if uploadToAppStoreConnect && !allowSigning {
            return "error: uploadToAppStoreConnect requires allowSigning=true"
        }
        if uploadToAppStoreConnect && (platform != .ios || exportMethod != "app-store-connect") {
            return "error: App Store Connect upload requires platform=ios and exportMethod=app-store-connect"
        }
        if uploadToAppStoreConnect && installDevice != nil {
            return "error: choose either App Store Connect upload or physical-device install"
        }
        if let signingIdentity {
            let identities = (try? AppleDeliverySupport.signingIdentities()) ?? []
            guard identities.contains(where: { $0.matches(signingIdentity) }) else {
                return "error: the selected signing identity is no longer valid in the macOS Keychain. Import or renew it, then rescan Signing & Device Delivery."
            }
        }

        let providedExportOptionsURL: URL?
        if let exportOptions = call.string("exportOptionsPlist")?.nilIfEmpty {
            guard allowSigning else {
                return "error: exportOptionsPlist requires allowSigning=true"
            }
            guard platform == .ios else {
                return "error: exportOptionsPlist is only supported for iOS releases"
            }
            guard !uploadToAppStoreConnect else {
                return "error: uploadToAppStoreConnect uses a generated upload configuration; remove exportOptionsPlist"
            }
            providedExportOptionsURL = try context.workspace.resolve(exportOptions, access: .read).url
        } else {
            providedExportOptionsURL = nil
        }

        let releaseDirectory = try Self.makeReleaseDirectory(
            workspace: context.workspace.root,
            scheme: scheme)
        let derivedData = releaseDirectory.appendingPathComponent("DerivedData", isDirectory: true)
        let archiveURL = releaseDirectory.appendingPathComponent("\(Self.fileSafe(scheme)).xcarchive")
        let verificationLog = releaseDirectory.appendingPathComponent("verification.log")
        let archiveLog = releaseDirectory.appendingPathComponent("archive.log")
        let exportLog = releaseDirectory.appendingPathComponent("export.log")
        let reportURL = releaseDirectory.appendingPathComponent("Ship-Report.md")
        try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        let exportOptionsURL: URL?
        if let providedExportOptionsURL {
            exportOptionsURL = providedExportOptionsURL
        } else if allowSigning, platform == .ios {
            let generated = releaseDirectory.appendingPathComponent("ExportOptions.plist")
            try Self.writeExportOptions(
                to: generated,
                method: exportMethod,
                identity: signingIdentity,
                teamID: developmentTeam,
                destination: uploadToAppStoreConnect ? "upload" : "export")
            exportOptionsURL = generated
        } else {
            exportOptionsURL = nil
        }

        var stages: [Stage] = []
        if shouldVerify {
            let action = BuildDiagnosticsTool.hasTestSources(in: projectDirectory) ? "test" : "build"
            let result = try Self.runXcodebuild(
                container: container,
                scheme: scheme,
                configuration: configuration,
                destination: platform.verificationDestination,
                derivedData: derivedData,
                signingAllowed: false,
                trailingArguments: [action],
                workingDirectory: projectDirectory,
                cancellationRequested: { context.isCancellationRequested })
            try result.output.write(to: verificationLog, atomically: true, encoding: String.Encoding.utf8)
            stages.append(Stage(name: action == "test" ? "Tests" : "Verification build", result: result, log: verificationLog))
            if result.failed {
                try Self.writeReport(
                    to: reportURL,
                    scheme: scheme,
                    platform: platform,
                    configuration: configuration,
                    signed: allowSigning,
                    stages: stages,
                    artifact: nil,
                    checksum: nil)
                return Self.failure(stage: stages.last!, report: reportURL)
            }
        }

        var signingArguments: [String] = []
        if let signingIdentity { signingArguments.append("CODE_SIGN_IDENTITY=\(signingIdentity)") }
        if let developmentTeam { signingArguments.append("DEVELOPMENT_TEAM=\(developmentTeam)") }
        if let provisioningProfile {
            signingArguments.append("PROVISIONING_PROFILE_SPECIFIER=\(provisioningProfile)")
        }
        if allowProvisioningUpdates { signingArguments.append("-allowProvisioningUpdates") }

        let archiveResult = try Self.runXcodebuild(
            container: container,
            scheme: scheme,
            configuration: configuration,
            destination: platform.archiveDestination,
            derivedData: derivedData,
            signingAllowed: allowSigning,
            trailingArguments: signingArguments + [
                "-archivePath", archiveURL.path,
                "SKIP_INSTALL=NO",
                "archive",
            ],
            workingDirectory: projectDirectory,
            cancellationRequested: { context.isCancellationRequested })
        try archiveResult.output.write(to: archiveLog, atomically: true, encoding: String.Encoding.utf8)
        stages.append(Stage(name: "Release archive", result: archiveResult, log: archiveLog))
        if archiveResult.failed {
            try Self.writeReport(
                to: reportURL,
                scheme: scheme,
                platform: platform,
                configuration: configuration,
                signed: allowSigning,
                stages: stages,
                artifact: nil,
                checksum: nil)
            return Self.failure(stage: stages.last!, report: reportURL)
        }

        var artifact = archiveURL
        if let exportOptionsURL {
            let exportDirectory = releaseDirectory.appendingPathComponent("Export", isDirectory: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            var exportArguments = [
                "-exportArchive",
                "-archivePath", archiveURL.path,
                "-exportPath", exportDirectory.path,
                "-exportOptionsPlist", exportOptionsURL.path,
            ]
            if allowProvisioningUpdates { exportArguments.append("-allowProvisioningUpdates") }
            let exportResult = try ShellRunner.runProcess(
                executable: "/usr/bin/xcodebuild",
                arguments: exportArguments,
                workingDirectory: projectDirectory,
                timeout: 900,
                cancelCheck: { context.isCancellationRequested })
            try exportResult.output.write(to: exportLog, atomically: true, encoding: String.Encoding.utf8)
            stages.append(Stage(
                name: uploadToAppStoreConnect ? "App Store Connect upload" : "Signed IPA export",
                result: exportResult,
                log: exportLog))
            if exportResult.failed {
                try Self.writeReport(
                    to: reportURL,
                    scheme: scheme,
                    platform: platform,
                    configuration: configuration,
                    signed: allowSigning,
                    stages: stages,
                    artifact: archiveURL,
                    checksum: nil)
                return Self.failure(stage: stages.last!, report: reportURL)
            }
            artifact = uploadToAppStoreConnect
                ? archiveURL
                : Self.firstFile(withExtension: "ipa", in: exportDirectory) ?? exportDirectory
        } else if platform == .macos,
                  let app = Self.firstFile(withExtension: "app", in: archiveURL.appendingPathComponent("Products/Applications")) {
            artifact = app
        }

        var installedDeviceName: String?
        if let installDevice {
            guard artifact.pathExtension.lowercased() == "ipa" else {
                return "error: signed IPA export did not produce an installable artifact"
            }
            let installResult = try AppleDeliverySupport.install(
                ipa: artifact,
                requestedDeviceID: installDevice,
                stagingDirectory: releaseDirectory.appendingPathComponent("DeviceInstall", isDirectory: true),
                cancellationRequested: { context.isCancellationRequested })
            let installLog = releaseDirectory.appendingPathComponent("device-install.log")
            try installResult.result.output.write(
                to: installLog, atomically: true, encoding: String.Encoding.utf8)
            let installStage = Stage(
                name: "Install on \(installResult.device.name)",
                result: installResult.result,
                log: installLog)
            stages.append(installStage)
            if installStage.result.failed {
                try Self.writeReport(
                    to: reportURL,
                    scheme: scheme,
                    platform: platform,
                    configuration: configuration,
                    signed: allowSigning,
                    stages: stages,
                    artifact: artifact,
                    checksum: nil)
                return Self.installFailure(
                    stage: installStage,
                    device: installResult.device,
                    report: reportURL)
            }
            installedDeviceName = installResult.device.name
        }

        let packageURL = releaseDirectory.appendingPathComponent(
            "\(Self.fileSafe(scheme))-\(platform.rawValue).zip")
        let packageResult = try ShellRunner.runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", artifact.path, packageURL.path],
            workingDirectory: releaseDirectory,
            timeout: 600,
            cancelCheck: { context.isCancellationRequested })
        let packageLog = releaseDirectory.appendingPathComponent("package.log")
        try packageResult.output.write(to: packageLog, atomically: true, encoding: String.Encoding.utf8)
        stages.append(Stage(name: "Package", result: packageResult, log: packageLog))
        if packageResult.failed {
            try Self.writeReport(
                to: reportURL,
                scheme: scheme,
                platform: platform,
                configuration: configuration,
                signed: allowSigning,
                stages: stages,
                artifact: artifact,
                checksum: nil)
            return Self.failure(stage: stages.last!, report: reportURL)
        }

        let checksum = ContentDigest.fileDigest(at: packageURL)
        if let checksum {
            try "\(checksum)  \(packageURL.lastPathComponent)\n"
                .write(to: releaseDirectory.appendingPathComponent("SHA256SUMS.txt"), atomically: true, encoding: .utf8)
        }
        try Self.writeReport(
            to: reportURL,
            scheme: scheme,
            platform: platform,
            configuration: configuration,
            signed: allowSigning,
            stages: stages,
            artifact: packageURL,
            checksum: checksum)

        return """
        Ship Center: ready
        Platform: \(platform.displayName)
        Scheme: \(scheme) (\(configuration))
        Signing: \(allowSigning ? "enabled" : "unsigned archive")
        \(uploadToAppStoreConnect ? "Uploaded: App Store Connect" : "")
        \(installedDeviceName.map { "Installed: \($0)" } ?? "")
        Artifact: \(packageURL.path)
        SHA-256: \(checksum ?? "unavailable")
        Report: \(reportURL.path)
        """
    }
}

extension AppleShipTool {
    struct Stage {
        let name: String
        let result: CommandResult
        let log: URL
    }

    static func projectDirectory(_ path: String?, in workspace: Workspace) throws -> URL {
        guard let path = path?.nilIfEmpty, path != "." else { return workspace.root }
        return try workspace.resolve(path, access: .read).url
    }

    static func detectContainer(in directory: URL) throws -> Container {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        if let workspace = children
            .filter({ $0.pathExtension == "xcworkspace" && $0.lastPathComponent != "project.xcworkspace" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first {
            return .workspace(workspace)
        }
        if let project = children
            .filter({ $0.pathExtension == "xcodeproj" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first {
            return .project(project)
        }
        throw ToolError.missingArgument("project — no .xcworkspace or .xcodeproj found in \(directory.path)")
    }

    static func resolvePlatform(_ requested: String?, in directory: URL, container: Container) throws -> Platform {
        switch requested?.lowercased() ?? "auto" {
        case "ios": return .ios
        case "macos": return .macos
        case "auto", "":
            if let detected = detectPlatform(in: directory, container: container) { return detected }
            throw ToolError.missingArgument("platform — could not auto-detect iOS or macOS; pass platform explicitly")
        default:
            throw ToolError.missingArgument("platform — expected auto, ios, or macos")
        }
    }

    static func detectPlatform(in directory: URL, container: Container) -> Platform? {
        let candidates = [
            directory.appendingPathComponent("project.yml"),
            container.url.appendingPathComponent("project.pbxproj"),
        ]
        for candidate in candidates {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            if text.range(of: #"platform:\s*iOS"#, options: [.regularExpression, .caseInsensitive]) != nil
                || text.contains("SDKROOT = iphoneos") {
                return .ios
            }
            if text.range(of: #"platform:\s*macOS"#, options: [.regularExpression, .caseInsensitive]) != nil
                || text.contains("SDKROOT = macosx") {
                return .macos
            }
        }
        return nil
    }

    static func makeReleaseDirectory(workspace: URL, scheme: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: Date()))-\(fileSafe(scheme))-\(UUID().uuidString.prefix(6))"
        let directory = workspace
            .appendingPathComponent(".beetcode/releases", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func runXcodebuild(
        container: Container,
        scheme: String,
        configuration: String,
        destination: String,
        derivedData: URL,
        signingAllowed: Bool,
        trailingArguments: [String],
        workingDirectory: URL,
        cancellationRequested: @escaping @Sendable () -> Bool
    ) throws -> CommandResult {
        var arguments = container.xcodebuildArguments + [
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", destination,
            "-derivedDataPath", derivedData.path,
        ]
        if !signingAllowed {
            arguments += ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
        }
        arguments += trailingArguments
        return try ShellRunner.runProcess(
            executable: "/usr/bin/xcodebuild",
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: 1_200,
            cancelCheck: cancellationRequested)
    }

    static func firstFile(withExtension pathExtension: String, in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == pathExtension {
            enumerator.skipDescendants()
            return url
        }
        return nil
    }

    static func fileSafe(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(scalars)
        return result.isEmpty ? "App" : result
    }

    static func exportMethod(_ requested: String?) throws -> String {
        let method = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "debugging"
        guard ["debugging", "release-testing", "app-store-connect", "enterprise"]
            .contains(method) else {
            throw ToolError.missingArgument(
                "exportMethod — expected debugging, release-testing, app-store-connect, or enterprise")
        }
        return method
    }

    static func writeExportOptions(
        to url: URL,
        method: String,
        identity _: String?,
        teamID: String?,
        destination: String = "export"
    ) throws {
        var options: [String: Any] = [
            "destination": destination,
            "method": method,
            "signingStyle": "automatic",
            "stripSwiftSymbols": true,
        ]
        if let teamID { options["teamID"] = teamID }
        let data = try PropertyListSerialization.data(
            fromPropertyList: options,
            format: .xml,
            options: 0)
        try data.write(to: url, options: .atomic)
    }

    static func writeReport(
        to url: URL,
        scheme: String,
        platform: Platform,
        configuration: String,
        signed: Bool,
        stages: [Stage],
        artifact: URL?,
        checksum: String?
    ) throws {
        let stageLines = stages.map { stage in
            let state = stage.result.failed ? "Failed" : "Passed"
            return "- \(stage.name): **\(state)** (log: `\(stage.log.lastPathComponent)`)"
        }.joined(separator: "\n")
        let artifactLine = artifact.map { "`\($0.path)`" } ?? "Not produced"
        let checksumLine = checksum.map { "`\($0)`" } ?? "Not available"
        let report = """
        # Ship Report

        - Scheme: `\(scheme)`
        - Platform: \(platform.displayName)
        - Configuration: `\(configuration)`
        - Signing: \(signed ? "Enabled" : "Disabled (unsigned archive)")
        - Created: \(Date().formatted(.iso8601))

        ## Checks

        \(stageLines)

        ## Artifact

        \(artifactLine)

        SHA-256: \(checksumLine)
        """
        try report.write(to: url, atomically: true, encoding: .utf8)
    }

    static func failure(stage: Stage, report: URL) -> String {
        let diagnostics = DiagnosticParser.render(DiagnosticParser.parse(stage.result.output))
        return """
        error: Ship Center stopped at \(stage.name.lowercased()).
        \(diagnostics)
        Log: \(stage.log.path)
        Report: \(report.path)
        """
    }

    static func installFailure(stage: Stage, device: AppleConnectedDevice, report: URL) -> String {
        """
        error: Ship Center could not install on \(device.name).
        \(AppleDeliverySupport.diagnoseInstallFailure(stage.result.output))
        Log: \(stage.log.path)
        Report: \(report.path)
        """
    }
}

struct AppleSigningIdentity: Identifiable, Sendable, Equatable {
    let fingerprint: String
    let name: String

    var id: String { fingerprint }

    var teamID: String? {
        guard let expression = try? NSRegularExpression(pattern: #"\(([A-Z0-9]{10})\)\s*$"#),
              let match = expression.firstMatch(
                in: name,
                range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name)
        else { return nil }
        return String(name[range])
    }

    func matches(_ value: String) -> Bool {
        fingerprint.caseInsensitiveCompare(value) == .orderedSame
            || name.caseInsensitiveCompare(value) == .orderedSame
    }
}

struct AppleConnectedDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let model: String
    let state: String
    let isPhysical: Bool

    var isConnected: Bool {
        state.localizedCaseInsensitiveContains("connected")
            || state.localizedCaseInsensitiveContains("available")
    }
}

/// Local Apple signing and device-delivery helpers shared by the native setup
/// sheet and `apple_ship`. They use argument arrays only; no shell evaluates
/// identity names, paths, or device identifiers.
enum AppleDeliverySupport {
    struct Installation: Sendable {
        let device: AppleConnectedDevice
        let result: CommandResult
    }

    static func signingIdentities() throws -> [AppleSigningIdentity] {
        let result = try ShellRunner.runProcess(
            executable: "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: 20)
        return parseSigningIdentities(result.output)
    }

    static func parseSigningIdentities(_ output: String) -> [AppleSigningIdentity] {
        guard let expression = try? NSRegularExpression(
            pattern: #"^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+\"([^\"]+)\"\s*$"#,
            options: [.anchorsMatchLines])
        else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        return expression.matches(in: output, range: range).compactMap { match in
            guard let fingerprintRange = Range(match.range(at: 1), in: output),
                  let nameRange = Range(match.range(at: 2), in: output)
            else { return nil }
            return AppleSigningIdentity(
                fingerprint: String(output[fingerprintRange]).uppercased(),
                name: String(output[nameRange]))
        }
    }

    static func connectedDevices() throws -> [AppleConnectedDevice] {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        let result = try ShellRunner.runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "list", "devices", "--json-output", jsonURL.path],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: 60)
        guard !result.failed, let data = try? Data(contentsOf: jsonURL) else { return [] }
        return parseDevices(data)
    }

    static func parseDevices(_ data: Data) -> [AppleConnectedDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]]
        else { return [] }
        return devices.compactMap { device in
            guard let identifier = device["identifier"] as? String else { return nil }
            let deviceProperties = device["deviceProperties"] as? [String: Any]
            let hardwareProperties = device["hardwareProperties"] as? [String: Any]
            let connectionProperties = device["connectionProperties"] as? [String: Any]
            let name = deviceProperties?["name"] as? String ?? "Apple device"
            let model = hardwareProperties?["marketingName"] as? String
                ?? hardwareProperties?["productType"] as? String
                ?? "iPhone or iPad"
            let reality = hardwareProperties?["reality"] as? String
                ?? device["reality"] as? String
                ?? ""
            let state = connectionProperties?["deviceAvailability"] as? String
                ?? connectionProperties?["transportType"] as? String
                ?? device["state"] as? String
                ?? "Unknown"
            return AppleConnectedDevice(
                id: identifier,
                name: name,
                model: model,
                state: state,
                isPhysical: reality.localizedCaseInsensitiveContains("physical"))
        }
    }

    static func install(
        ipa: URL,
        requestedDeviceID: String,
        stagingDirectory: URL,
        cancellationRequested: @escaping @Sendable () -> Bool
    ) throws -> Installation {
        let devices = try connectedDevices().filter { $0.isPhysical }
        let device: AppleConnectedDevice?
        if requestedDeviceID.caseInsensitiveCompare("auto") == .orderedSame {
            device = devices.first(where: \.isConnected)
        } else {
            device = devices.first { $0.id.caseInsensitiveCompare(requestedDeviceID) == .orderedSame }
        }
        guard let device else {
            return Installation(
                device: AppleConnectedDevice(
                    id: requestedDeviceID,
                    name: "connected iPhone or iPad",
                    model: "Apple device",
                    state: "Unavailable",
                    isPhysical: true),
                result: CommandResult(
                    exitCode: 1,
                    timedOut: false,
                    output: "No matching connected physical device was found. Connect and unlock it, trust this Mac, and enable Developer Mode."))
        }
        guard device.isConnected else {
            return Installation(
                device: device,
                result: CommandResult(
                    exitCode: 1,
                    timedOut: false,
                    output: "The selected device is unavailable. Connect and unlock it, then confirm the trust prompt."))
        }

        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let extraction = try ShellRunner.runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", ipa.path, stagingDirectory.path],
            workingDirectory: stagingDirectory,
            timeout: 300,
            cancelCheck: cancellationRequested)
        guard !extraction.failed,
              let app = AppleShipTool.firstFile(
                withExtension: "app",
                in: stagingDirectory.appendingPathComponent("Payload", isDirectory: true))
        else {
            return Installation(
                device: device,
                result: CommandResult(
                    exitCode: extraction.exitCode == 0 ? 1 : extraction.exitCode,
                    timedOut: extraction.timedOut,
                    output: extraction.output + "\nThe exported IPA did not contain Payload/*.app."))
        }

        let installResult = try ShellRunner.runProcess(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "install", "app",
                "--device", device.id,
                app.path,
            ],
            workingDirectory: stagingDirectory,
            timeout: 600,
            cancelCheck: cancellationRequested)
        return Installation(device: device, result: installResult)
    }

    static func diagnoseInstallFailure(_ output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("no matching connected") || lower.contains("unavailable") {
            return "Connect and unlock the iPhone or iPad, trust this Mac, and try again."
        }
        if lower.contains("developer mode") {
            return "Enable Developer Mode in Settings › Privacy & Security on the device, restart it, and try again."
        }
        if lower.contains("provision") || lower.contains("applicationverificationfailed") {
            return "The provisioning profile does not allow this device or app identifier. Use a Development or Ad Hoc profile that includes the device UDID."
        }
        if lower.contains("locked") || lower.contains("pairing") || lower.contains("trust") {
            return "Unlock the device and accept its trust or pairing prompt."
        }
        return "Check that the device is connected, paired, in Developer Mode, and covered by the selected provisioning profile."
    }
}

private extension String {
    var nilIfEmpty: String? {
        guard !isEmpty else { return nil }
        return self
    }
}
