import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Computer use: lets the agent observe and drive ANY macOS app, Claude-style.
///
/// Observation is dual-path by design:
/// - `computer_ui_tree` reads the Accessibility tree as TEXT — the reliable
///   path for local text-only models (Hermes, Qwythos): they get exact
///   element names and screen coordinates instead of guessing from pixels.
/// - `computer_screenshot` + `describe_image` is the pixel path for
///   vision-capable providers (BYOK GPT-4o/Claude, local SmolVLM2).
///
/// macOS gates this behind two TCC permissions, checked per call with a
/// clear error instead of a silent no-op:
/// - Accessibility (AX tree + posting CGEvents)
/// - Screen Recording (ScreenCaptureKit screenshots)
///
/// Observation tools are `.read` (auto-approved); every action that moves
/// the mouse, types, or scrolls is `.execute` and passes through the same
/// approval card as shell commands.

// MARK: - Permission preflight

enum ComputerPermission {
    /// Accessibility: required for the AX tree AND for posting input events.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Screen Recording: required for ScreenCaptureKit captures.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt for Accessibility (shows the Settings pane).
    static func requestAccessibility() {
        // NOTE: the SDK declares kAXTrustedCheckOptionPrompt as a mutable
        // `var`, so referencing it is a concurrency error under approachable
        // concurrency. The key's value is the stable, documented literal
        // below — using it directly sidesteps the shared-mutable-state
        // diagnostic without `nonisolated(unsafe)` hacks.
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Triggers the system prompt for Screen Recording.
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}

enum ComputerUseError: Error, LocalizedError {
    case accessibilityNotGranted
    case screenRecordingNotGranted
    case noFocusedApp
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission is not granted — enable BeetCode in System Settings → Privacy & Security → Accessibility (or the Settings → Agent → Computer control card), then retry."
        case .screenRecordingNotGranted:
            return "Screen Recording permission is not granted — enable BeetCode in System Settings → Privacy & Security → Screen Recording (or the Settings → Agent → Computer control card), then retry."
        case .noFocusedApp:
            return "No focused application to inspect."
        case .unknownKey(let name):
            return "Unknown key '\(name)'. Named keys: return, tab, escape, space, delete, forward_delete, left, right, up, down, home, end, page_up, page_down, f1…f12."
        }
    }
}

// MARK: - Keyboard mapping (pure, unit-tested)

enum ComputerKey {
    /// Named key → virtual keycode. Also accepts single characters.
    static func keyCode(for name: String) -> CGKeyCode? {
        let table: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
            "backspace": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "page_up": 116, "page_down": 121,
            "forward_delete": 117, "help": 114,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        if let code = table[name.lowercased()] { return code }
        // Single printable characters: map the common US-layout ones.
        guard name.count == 1, let char = name.lowercased().first else { return nil }
        let chars: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "9": 27, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        return chars[char]
    }

    /// Modifier names → CGEventFlags.
    static func modifiers(for names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }
}

// MARK: - Event posting

enum ComputerEvents {
    /// Clamps model-supplied coordinates to the union of all screens so a
    /// hallucinated point can never target outside the displays.
    static func clamped(_ x: Double, _ y: Double) -> CGPoint {
        var bounds = CGRect.null
        for screen in NSScreen.screens { bounds = bounds.union(screen.frame) }
        // NSScreen frames are bottom-left origin; CGEvents use top-left.
        // The primary screen's height converts between the two.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? bounds.height
        let cgY = primaryHeight - y
        let clampedX = min(max(x, bounds.minX), bounds.maxX - 1)
        let clampedYFlipped = min(max(cgY, 0), primaryHeight - 1)
        return CGPoint(x: clampedX, y: clampedYFlipped)
    }

    static func postMouseClick(at point: CGPoint, button: CGMouseButton, clickCount: Int) {
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let source = CGEventSource(stateID: .hidSystemState)
        for state in 1...max(1, clickCount) {
            if let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
               let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button) {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                up.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            usleep(60_000)
        }
    }

    static func postMouseMove(to point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Types text as Unicode keystrokes — handles any layout/emoji, unlike
    /// per-character virtual keycodes.
    static func postText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            var units = Array(String(scalar).utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }

    static func postKey(_ code: CGKeyCode, modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func postScroll(at point: CGPoint, dx: Int, dy: Int) {
        postMouseMove(to: point)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?
            .post(tap: .cghidEventTap)
    }
}

// MARK: - AX tree extraction

/// One flattened accessibility node. Value type so the walker (AppKit-free
/// except AX C APIs) stays testable: rendering is a pure function over these.
struct AXNodeInfo: Sendable, Equatable {
    var depth: Int
    var role: String
    var label: String
    var value: String
    var frame: CGRect
    var enabled: Bool
}

enum AXTreeWalker {
    static let maxDepth = 14
    static let maxNodes = 400

    /// Roles that carry no interaction or label value on their own.
    private static let noiseRoles: Set<String> = [
        "AXScrollArea", "AXGroup", "AXLayoutArea", "AXUnknown",
    ]

    /// Flattens the focused app's AX tree. Returns nil when nothing is focused.
    static func flattenFocusedApp() -> [AXNodeInfo]? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &focusedRef) == .success,
            let focusedRef
        else { return nil }
        // swiftlint:disable:next force_cast — AX contract guarantees AXUIElement.
        let app = focusedRef as! AXUIElement
        var nodes: [AXNodeInfo] = []
        walk(app, depth: 0, into: &nodes)
        return nodes
    }

    private static func walk(_ element: AXUIElement, depth: Int, into nodes: inout [AXNodeInfo]) {
        guard depth <= maxDepth, nodes.count < maxNodes else { return }

        let role = stringAttribute(kAXRoleAttribute, of: element) ?? "AXUnknown"
        let label = stringAttribute(kAXTitleAttribute, of: element)
            ?? stringAttribute(kAXDescriptionAttribute, of: element)
            ?? ""
        let value = stringAttribute(kAXValueAttribute, of: element) ?? ""
        let frame = frameAttribute(of: element)
        let enabled = boolAttribute(kAXEnabledAttribute, of: element) ?? true

        // Keep structural noise out of the model's context unless it carries
        // a label — unlabeled AXGroups are the bulk of any tree.
        if !noiseRoles.contains(role) || !label.isEmpty || !value.isEmpty {
            nodes.append(AXNodeInfo(
                depth: depth, role: role, label: label, value: value,
                frame: frame, enabled: enabled))
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
            let children = childrenRef as? [AXUIElement]
        else { return }
        for child in children {
            walk(child, depth: depth + 1, into: &nodes)
            if nodes.count >= maxNodes { return }
        }
    }

    /// One compact line per node: `button "Save" at (840,620) 64×28`.
    /// Coordinates are screen points in TOP-LEFT origin — the same space
    /// computer_click/computer_scroll take.
    static func render(_ nodes: [AXNodeInfo]) -> String {
        guard !nodes.isEmpty else { return "(no accessible elements found)" }
        var lines: [String] = []
        for node in nodes {
            let indent = String(repeating: "  ", count: min(node.depth, 10))
            var parts = [indent + node.role]
            if !node.label.isEmpty { parts.append("\"\(node.label)\"") }
            if !node.value.isEmpty, node.value != node.label {
                parts.append("value \"\(String(node.value.prefix(120)))\"")
            }
            if node.frame != .zero {
                parts.append("at (\(Int(node.frame.midX)),\(Int(node.frame.midY)))")
                parts.append("\(Int(node.frame.width))×\(Int(node.frame.height))")
            }
            if !node.enabled { parts.append("[disabled]") }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Attribute helpers

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        if let string = ref as? String { return string }
        if let number = ref as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let number = ref as? NSNumber
        else { return nil }
        return number.boolValue
    }

    /// AX frames arrive in top-left origin screen points already.
    private static func frameAttribute(of element: AXUIElement) -> CGRect {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return .zero }
        var position = CGPoint.zero
        var size = CGSize.zero
        if let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID() {
            AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        }
        if let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }
}

// MARK: - Tools

struct ComputerStatusTool: AgentTool {
    let name = "computer_status"
    let summary = "Report computer-use permission status and the focused app"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{},"required":[]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let ax = ComputerPermission.accessibilityGranted
        let sr = ComputerPermission.screenRecordingGranted
        let frontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "(none)"
        }
        return """
        focused app: \(frontmost)
        accessibility: \(ax ? "granted" : "NOT granted — computer_ui_tree/click/type/key/scroll will fail")
        screen recording: \(sr ? "granted" : "NOT granted — computer_screenshot will fail")
        """
    }
}

struct ComputerUITreeTool: AgentTool {
    let name = "computer_ui_tree"
    let summary = "Read the focused Mac app's accessibility tree (names + screen coordinates)"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{},"required":[]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        guard let nodes = AXTreeWalker.flattenFocusedApp() else {
            throw ComputerUseError.noFocusedApp
        }
        return AXTreeWalker.render(nodes)
    }
}

struct ComputerScreenshotTool: AgentTool {
    let name = "computer_screenshot"
    let summary = "Capture the focused Mac app's window to a PNG in the workspace"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "fullScreen":{"type":"boolean","description":"Capture the whole main display instead of the focused window"}
        },"required":[]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.screenRecordingGranted else {
            throw ComputerUseError.screenRecordingNotGranted
        }
        let fullScreen = call.bool("fullScreen") ?? false
        let image = try await Self.capture(fullScreen: fullScreen)
        let dir = context.workspace.root.appendingPathComponent(".beetcode/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ToolError.commandFailed(exitCode: 1)
        }
        try data.write(to: file)
        return "screenshot saved to \(file.path) — pass it to describe_image to see the screen."
    }

    /// SCScreenshotManager (macOS 14+): one call, no stream lifecycle.
    @MainActor
    private static func capture(fullScreen: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw ComputerUseError.noFocusedApp
        }
        let filter: SCContentFilter
        if fullScreen {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else if let window = content.windows.first(where: {
            $0.isOnScreen && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.showsCursor = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

struct ComputerClickTool: AgentTool {
    let name = "computer_click"
    let summary = "Click the Mac screen at screen coordinates (top-left origin)"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "x":{"type":"integer","description":"Screen X in points, top-left origin — use coordinates from computer_ui_tree"},
          "y":{"type":"integer","description":"Screen Y in points, top-left origin"},
          "button":{"type":"string","enum":["left","right"],"description":"Default left"},
          "clickCount":{"type":"integer","description":"2 for double-click. Default 1"}
        },"required":["x","y"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let x = call.number("x"), let y = call.number("y") else { return .none }
        return .command("computer_click at (\(Int(x)), \(Int(y)))")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        guard let x = call.number("x"), let y = call.number("y") else {
            throw ToolError.missingArgument("x/y")
        }
        let button: CGMouseButton = (call.string("button") == "right") ? .right : .left
        let count = call.int("clickCount") ?? 1
        let point = ComputerEvents.clamped(x, y)
        ComputerEvents.postMouseClick(at: point, button: button, clickCount: count)
        return "clicked \(button == .left ? "left" : "right")×\(count) at (\(Int(point.x)), \(Int(y)))"
    }
}

struct ComputerTypeTool: AgentTool {
    let name = "computer_type"
    let summary = "Type text into whatever has keyboard focus on the Mac"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "text":{"type":"string","description":"Text to type (any layout, Unicode-safe)"}
        },"required":["text"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let text = call.string("text") else { return .none }
        return .command("computer_type \"\(String(text.prefix(80)))\"")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        guard let text = call.string("text") else { throw ToolError.missingArgument("text") }
        ComputerEvents.postText(text)
        return "typed \(text.count) character(s)"
    }
}

struct ComputerKeyTool: AgentTool {
    let name = "computer_key"
    let summary = "Press a named key or shortcut (e.g. cmd+s, return, tab, arrows)"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "key":{"type":"string","description":"return, tab, escape, space, delete, left/right/up/down, home, end, page_up, page_down, f1…f12, or a single character"},
          "modifiers":{"type":"array","items":{"type":"string","enum":["cmd","shift","alt","ctrl"]},"description":"Held while pressing, e.g. pass [cmd] for cmd+s"}
        },"required":["key"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let key = call.string("key") else { return .none }
        let mods = call.strings("modifiers").joined(separator: "+")
        return .command("computer_key \(mods.isEmpty ? key : mods + "+" + key)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        guard let key = call.string("key") else { throw ToolError.missingArgument("key") }
        guard let code = ComputerKey.keyCode(for: key) else {
            throw ComputerUseError.unknownKey(key)
        }
        let modifiers = ComputerKey.modifiers(for: call.strings("modifiers"))
        ComputerEvents.postKey(code, modifiers: modifiers)
        return "pressed \(key)"
    }
}

struct ComputerScrollTool: AgentTool {
    let name = "computer_scroll"
    let summary = "Scroll at a screen position (pixels; negative dy scrolls up)"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "x":{"type":"integer"},"y":{"type":"integer"},
          "dx":{"type":"integer","description":"Horizontal scroll pixels. Default 0"},
          "dy":{"type":"integer","description":"Vertical scroll pixels; negative = up, positive = down"}
        },"required":["x","y","dy"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let dy = call.int("dy") ?? 0
        return .command("computer_scroll dy=\(dy)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        guard let x = call.number("x"), let y = call.number("y") else {
            throw ToolError.missingArgument("x/y")
        }
        let dx = call.int("dx") ?? 0
        guard let dy = call.int("dy") else { throw ToolError.missingArgument("dy") }
        let point = ComputerEvents.clamped(x, y)
        ComputerEvents.postScroll(at: point, dx: dx, dy: dy)
        return "scrolled dx=\(dx) dy=\(dy) at (\(Int(point.x)), \(Int(y)))"
    }
}
