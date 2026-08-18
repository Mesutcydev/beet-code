import AppKit
import Foundation

/// Formalized simulator state + control surface. Owns device listing,
/// selection, boot/shutdown, app install/launch, and the live screenshot
/// stream. The panel observes this; agent tools drive the same devices via
/// argent with explicit UDIDs. All subprocess work happens off-main.
@MainActor
final class SimulatorContext: ObservableObject {

    struct SimDevice: Identifiable, Equatable {
        let udid: String
        let name: String
        let runtime: String
        let state: String
        var id: String { udid }
    }

    @Published private(set) var devices: [SimDevice] = []
    @Published private(set) var selectedUDID: String?
    @Published private(set) var screenshot: NSImage?
    @Published private(set) var isStreaming = false
    @Published private(set) var lastError: String?
    @Published var lastConsoleOutput: String?

    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var selectedDevice: SimDevice? {
        devices.first { $0.udid == selectedUDID }
    }

    // MARK: Devices

    /// simctl writes CoreSimulator warnings to stderr, and the shell runner
    /// merges stderr into stdout — the raw blob can carry junk around the
    /// JSON. Scan for the outermost JSON object and return only that.
    nonisolated static func jsonObject(in text: String) -> Data? {
        guard let start = text.firstIndex(of: Character(UnicodeScalar(0x7B)!)) else {
            return text.data(using: .utf8)
        }
        let quote = Character(UnicodeScalar(0x22)!)
        let backslash = Character(UnicodeScalar(0x5C)!)
        let open = Character(UnicodeScalar(0x7B)!)
        let close = Character(UnicodeScalar(0x7D)!)
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.indices[start...] {
            let ch = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == backslash {
                    escaped = true
                } else if ch == quote {
                    inString = false
                }
                continue
            }
            if ch == quote {
                inString = true
            } else if ch == open {
                depth += 1
            } else if ch == close {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index]).data(using: .utf8)
                }
            }
        }
        return nil
    }

    /// Lists available devices; refreshes asynchronously (never blocks UI).
    func refreshDevices() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let result = await SimctlRunner.run(["list", "devices", "-j"])
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.applyDeviceList(result)
            }
        }
    }

    private func applyDeviceList(_ result: String) {
        guard !result.isEmpty else {
            lastError = "xcrun simctl unavailable"
            return
        }
        guard let data = Self.jsonObject(in: result),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]]
        else {
            let preview = result.prefix(200)
            lastError = "unable to parse device list: \(preview)"
            return
        }
        var found: [SimDevice] = []
        for (runtime, entries) in runtimes.sorted(by: { $0.key < $1.key }) {
            for entry in entries {
                guard let udid = entry["udid"] as? String,
                      let name = entry["name"] as? String,
                      let state = entry["state"] as? String
                else { continue }
                // Unavailable devices cannot boot or stream — never list them.
                if let available = entry["isAvailable"] as? Bool, !available { continue }
                found.append(SimDevice(udid: udid, name: name, runtime: runtime, state: state))
            }
        }
        devices = found

        // Reconcile a stale selection: keep it only when it still exists;
        // otherwise prefer an already-booted device, then the first device.
        if let current = selectedUDID, found.contains(where: { $0.udid == current }) {
            // keep
        } else {
            selectedUDID = found.first(where: { $0.state.contains("Booted") })?.udid
                ?? found.first?.udid
        }
        lastError = nil

        // A booted device should stream immediately after refresh — the panel
        // opening on a running simulator is the common case.
        if let selected = selectedDevice, selected.state.contains("Booted") {
            startStreaming()
        }
    }

    func select(_ device: SimDevice) {
        selectedUDID = device.udid
        stopStreaming()
        if device.state.contains("Booted") {
            startStreaming()
        }
    }

    func bootSelected() {
        guard let udid = selectedUDID else { return }
        Task { [weak self] in
            let boot = await SimctlRunner.run(["boot", udid], timeout: SimctlRunner.bootTimeout)
            // Wait until the device is fully booted before streaming:
            // screenshot attempts against a booting device fail noisily.
            let status = await SimctlRunner.run(
                ["bootstatus", udid, "-b"],
                timeout: SimctlRunner.bootTimeout)
            await MainActor.run {
                guard let self else { return }
                let bootFailed = boot.contains("error") || boot.contains("Unable")
                self.lastError = bootFailed ? boot : (status.contains("error") ? status : nil)
                self.refreshDevices()
                self.startStreaming()
            }
        }
    }

    func shutdownSelected() {
        guard let udid = selectedUDID else { return }
        stopStreaming()
        Task {
            _ = await SimctlRunner.run(["shutdown", udid])
            await MainActor.run { self.refreshDevices() }
        }
    }

    /// Installs a built .app bundle and launches its binary.
    func installAndLaunch(appBundle: URL, bundleIdentifier: String? = nil) {
        guard let udid = selectedUDID else {
            lastError = "Select a simulator device first."
            return
        }
        let identifier = bundleIdentifier
            ?? (Bundle(url: appBundle)?.bundleIdentifier)
            ?? SimulatorContext.bundleIdentifier(of: appBundle)
        Task { [weak self] in
            let install = await SimctlRunner.run(["install", udid, appBundle.path])
            guard install.isEmpty || !install.contains("error") else {
                await MainActor.run { self?.lastError = "install failed: \(install)" }
                return
            }
            guard let identifier else {
                await MainActor.run { self?.lastError = "could not determine bundle identifier" }
                return
            }
            let launch = await SimctlRunner.run(["launch", udid, identifier])
            await MainActor.run {
                guard let self else { return }
                self.lastConsoleOutput = "launch \(identifier): \(launch)"
                self.lastError = launch.contains("error") ? launch : nil
                self.startStreaming()
            }
        }
    }

    /// Reads the bundle identifier from the app's Info.plist.
    nonisolated static func bundleIdentifier(of appBundle: URL) -> String? {
        SimctlRunner.bundleIdentifier(of: appBundle)
    }

    // MARK: Screenshot stream

    private var streamGeneration = UUID()

    /// Polls `simctl io screenshot` at ~2 fps in a DETACHED task; only the
    /// image publish hops to the main actor. A generation UUID makes stale
    /// task cleanup impossible: a cancelled task can only clear state if it
    /// still owns the current generation.
    func startStreaming() {
        guard selectedUDID != nil, streamTask == nil else { return }
        isStreaming = true
        let udid = selectedUDID!
        let generation = UUID()
        streamGeneration = generation
        // Unique per-stream directory: a shared screen.png overwritten by
        // two streams could decode a torn or stale image.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-sim-\(generation.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shotURL = dir.appendingPathComponent("screen.png")
        streamTask = Task.detached(priority: .utility) { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: dir)
            }
            while !Task.isCancelled {
                let result = await SimctlRunner.run(["io", udid, "screenshot", shotURL.path])
                if result.contains("Unable") || result.contains("timed out") { break }
                // Decode from Data: a lazy NSImage tied to a file that gets
                // overwritten every 500 ms can read a half-written frame.
                if let data = try? Data(contentsOf: shotURL), let image = NSImage(data: data) {
                    await MainActor.run { self?.screenshot = image }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            await MainActor.run {
                guard let self, self.streamGeneration == generation else { return }
                self.isStreaming = false
                self.streamTask = nil
            }
        }
    }

    func stopStreaming() {
        streamGeneration = UUID()
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        screenshot = nil
    }
}