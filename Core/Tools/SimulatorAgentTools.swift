import Foundation

/// Agent tools that drive the iOS simulator through argent. Registered like
/// any other tool: reads are automatic, interactions (tap/swipe/type/boot)
/// go through the approval gate like any command.

struct SimListDevicesTool: AgentTool {
    let name = "sim_list_devices"
    let summary = "List iOS simulators (booted first) with their UDIDs"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{},"required":[]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let output = try ArgentBridge.run("list-devices", args: [:])
        return Summarize.argentOutput(output, tool: "list-devices")
    }
}

struct SimBootDeviceTool: AgentTool {
    let name = "sim_boot_device"
    let summary = "Boot an iOS simulator by UDID"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "udid":{"type":"string","description":"The simulator UDID from sim_list_devices"}
        },"required":["udid"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let udid = call.string("udid") else { return .none }
        return .command("argent run boot-device --udid \(udid)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let udid = call.string("udid") else { throw ToolError.missingArgument("udid") }
        let output = try ArgentBridge.run("boot-device", args: ["udid": udid])
        return Summarize.argentOutput(output, tool: "boot-device")
    }
}

struct SimLaunchAppTool: AgentTool {
    let name = "sim_launch_app"
    let summary = "Launch an app by bundle identifier on a simulator"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "udid":{"type":"string","description":"The simulator UDID"},
          "bundleId":{"type":"string","description":"The app's bundle identifier, e.g. com.example.app"}
        },"required":["udid","bundleId"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let udid = call.string("udid") else { throw ToolError.missingArgument("udid") }
        guard let bundleId = call.string("bundleId") else { throw ToolError.missingArgument("bundleId") }
        let output = try ArgentBridge.run(
            "launch-app",
            args: ["udid": udid, "bundleId": bundleId])
        return Summarize.argentOutput(output, tool: "launch-app")
    }
}

struct SimTapTool: AgentTool {
    let name = "sim_tap"
    let summary = "Tap the simulator screen at normalized coordinates (0–1 fractions)"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "udid":{"type":"string"},"x":{"type":"number","description":"0–1 fraction of width"},
          "y":{"type":"number","description":"0–1 fraction of height"}
        },"required":["udid","x","y"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let udid = call.string("udid") else { throw ToolError.missingArgument("udid") }
        guard let x = call.number("x") else { throw ToolError.missingArgument("x") }
        guard let y = call.number("y") else { throw ToolError.missingArgument("y") }
        let output = try ArgentBridge.run(
            "gesture-tap",
            args: ["udid": udid, "x": x, "y": y])
        return Summarize.argentOutput(output, tool: "gesture-tap")
    }
}

struct SimSwipeTool: AgentTool {
    let name = "sim_swipe"
    let summary = "Swipe on the simulator between normalized start/end points"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "udid":{"type":"string"},
          "startX":{"type":"number"},"startY":{"type":"number"},
          "endX":{"type":"number"},"endY":{"type":"number"},
          "durationMs":{"type":"integer","description":"Optional swipe duration"}
        },"required":["udid","startX","startY","endX","endY"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let udid = call.string("udid") else { throw ToolError.missingArgument("udid") }
        guard let sx = call.number("startX"), let sy = call.number("startY") else {
            throw ToolError.missingArgument("startX/startY")
        }
        guard let ex = call.number("endX"), let ey = call.number("endY") else {
            throw ToolError.missingArgument("endX/endY")
        }
        var args: [String: Any] = ["udid": udid, "startX": sx, "startY": sy, "endX": ex, "endY": ey]
        if let duration = call.int("durationMs") { args["durationMs"] = duration }
        let output = try ArgentBridge.run("gesture-swipe", args: args)
        return Summarize.argentOutput(output, tool: "gesture-swipe")
    }
}

struct SimTypeTool: AgentTool {
    let name = "sim_type"
    let summary = "Type text (or press special keys) on the simulator keyboard"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "udid":{"type":"string"},"text":{"type":"string"}
        },"required":["udid","text"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let udid = call.string("udid") else { throw ToolError.missingArgument("udid") }
        guard let text = call.string("text") else { throw ToolError.missingArgument("text") }
        let output = try ArgentBridge.run(
            "keyboard",
            args: ["udid": udid, "text": text])
        return Summarize.argentOutput(output, tool: "keyboard")
    }
}

struct SimDescribeTool: AgentTool {
    let name = "sim_describe"
    let summary = "Read the accessibility tree of the simulator's current screen"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "udid":{"type":"string"}
        },"required":["udid"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let udid = call.string("udid") else { throw ToolError.missingArgument("udid") }
        let output = try ArgentBridge.run("describe", args: ["udid": udid])
        return Summarize.argentOutput(output, tool: "describe", maxChars: 8_000)
    }
}

struct SimScreenshotTool: AgentTool {
    let name = "sim_screenshot"
    let summary = "Save a simulator screenshot into the workspace and return its path"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "udid":{"type":"string"}
        },"required":["udid"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let udid = call.string("udid") else { throw ToolError.missingArgument("udid") }
        // Save into a workspace-visible folder so the user (and future
        // vision tools) can inspect it.
        let dir = context.workspace.root.appendingPathComponent(".beetcode/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shot = dir.appendingPathComponent("sim-\(Int(Date().timeIntervalSince1970)).png")
        let output = try ArgentBridge.run(
            "screenshot",
            args: ["udid": udid],
            outputPath: shot.path)
        return "screenshot saved to \(shot.path)\n" + Summarize.argentOutput(output, tool: "screenshot")
    }
}

/// Tames verbose argent JSON output for the agent's context.
enum Summarize {
    static func argentOutput(_ output: String, tool: String, maxChars: Int = 4_000) -> String {
        // argent may print an update banner before the JSON payload.
        let jsonStart = output.firstIndex(of: "{")
        let clean = jsonStart.map { String(output[$0...]) } ?? output
        guard let data = clean.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(\(tool) returned no output)" : String(trimmed.prefix(maxChars))
        }
        // Compact: keep the interesting fields, drop screenshots URLs noise.
        let dropped = ["timestampMs", "screenshotPath", "url", "screenshot"]
        var summary: [String] = []
        for (key, value) in json.sorted(by: { $0.key < $1.key }) where !dropped.contains(key) {
            if let string = value as? String, !string.isEmpty {
                summary.append("\(key): \(String(string.prefix(600)))")
            } else if let number = value as? NSNumber {
                summary.append("\(key): \(number)")
            } else if let bool = value as? Bool {
                summary.append("\(key): \(bool)")
            } else if let array = value as? [Any], !array.isEmpty {
                summary.append("\(key): \(String(describing: array).prefix(1_500))")
            }
        }
        let joined = summary.joined(separator: "\n")
        return joined.isEmpty ? "(\(tool) returned no output)" : String(joined.prefix(maxChars))
    }
}