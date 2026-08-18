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
            HStack(alignment: .top, spacing: 0) {
                deviceList
                Divider()
                liveView
            }
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
        HStack {
            Label("iOS Simulator", systemImage: "iphone")
                .font(.title3.bold())
            if let device = controller.selectedDevice {
                Text(device.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isStreaming {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            }
            Button("Refresh") { controller.refreshDevices() }
                .controlSize(.small)
            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close the simulator panel")
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Devices").font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                ForEach(controller.devices) { device in
                    DeviceRow(
                        device: device,
                        isSelected: device.udid == controller.selectedUDID) {
                        controller.select(device)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Boot") { controller.bootSelected() }
                    .controlSize(.small)
                Button("Shutdown") { controller.shutdownSelected() }
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                Button("Install App…") { showInstaller = true }
                    .controlSize(.small)
                TextField("bundle id", text: $bundleID)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(3)
            }
            Divider()
            Text(ArgentBridge.isAvailable
                 ? "The agent can drive this simulator: sim_tap, sim_type, sim_describe, sim_screenshot (via argent)."
                 : "Install argent to let the agent interact (tap/type/describe).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 260)
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
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Boot a device to stream its screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.surfaceInset)
        .padding(8)
    }
}
private struct DeviceRow: View {
    let device: SimulatorContext.SimDevice
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: isBooted ? "iphone" : "iphone.slash")
                    .foregroundStyle(isBooted ? Theme.success : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.callout)
                    Text(device.runtime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(6)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var isBooted: Bool { device.state.contains("Booted") }
}