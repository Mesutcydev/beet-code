import AppKit
import SwiftUI

/// Built-in iOS Simulator panel: device list, boot/shutdown, app
/// install/launch, and a live screenshot stream. The AGENT can also drive
/// the simulator through argent-backed tools (sim_tap, sim_type, …) — this
/// panel is the human's viewport and control surface.
struct SimulatorPanelView: View {
    @StateObject private var controller = SimulatorContext()
    @EnvironmentObject private var appState: AppState
    @State private var bundleID = ""
    @State private var showInstaller = false
    /// Called when the user closes the side panel (there is no other way out).
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            liveView
        }
        // Fill the docked column (the parent decides width/height); never
        // impose a hard size that fights the layout.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            controller.refreshDevices()
        }
        .onDisappear {
            controller.stopStreaming()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("iOS Simulator", systemImage: "iphone")
                .font(.callout.weight(.semibold))
            if controller.isStreaming {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            }
            Spacer()
            devicePicker
            Button { controller.refreshDevices() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Refresh the device list")
            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close the simulator panel")
                // No .cancelAction here: Esc is owned by the composer's
                // stop button (stopping a run must never be ambiguous).
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Theme surface, not .bar material: Beet mode must tint this too.
        .background(Theme.surface)
    }

    /// The device list lives in a menu: in a 380–560 pt docked column a
    /// fixed 260-pt side list squeezed the phone screen to a postage stamp.
    private var devicePicker: some View {
        Menu {
            ForEach(controller.devices) { device in
                Button {
                    controller.select(device)
                } label: {
                    Label(
                        "\(device.name) — \(device.runtime)",
                        systemImage: device.udid == controller.selectedUDID
                            ? "checkmark.circle.fill"
                            : (device.state.contains("Booted") ? "iphone" : "iphone.slash"))
                }
            }
            if controller.devices.isEmpty {
                Text("No simulators found — create one in Xcode.")
            }
        } label: {
            HStack(spacing: 4) {
                Text(controller.selectedDevice?.name ?? "Select device")
                    .font(.callout)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the simulated device")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Boot") { controller.bootSelected() }
                    .controlSize(.small)
                Button("Shutdown") { controller.shutdownSelected() }
                    .controlSize(.small)
                Spacer()
                TextField("bundle id", text: $bundleID)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 120)
                Button("Install…") { showInstaller = true }
                    .controlSize(.small)
                    .help("Install and launch an .app on the selected device")
            }
            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(3)
            }
            Text(ArgentBridge.isAvailable
                 ? "The agent can drive this simulator: sim_tap, sim_type, sim_describe, sim_screenshot (via argent)."
                 : "Install argent to let the agent interact (tap/type/describe).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fileImporter(
            isPresented: $showInstaller,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let app = urls.first {
                controller.installAndLaunch(
                    appBundle: app,
                    bundleIdentifier: bundleID.isEmpty ? nil : bundleID)
            }
        }
    }

    private var liveView: some View {
        Group {
            if let image = controller.screenshot {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Boot a device to stream its screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceInset)
    }
}