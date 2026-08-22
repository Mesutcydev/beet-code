import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SystemReadinessModel {
    struct Snapshot: Sendable, Equatable {
        let isAppleSilicon: Bool
        let supportedSystem: Bool
        let xcodePath: String?
        let signingIdentityCount: Int
        let connectedDeviceCount: Int

        var xcodeReady: Bool { xcodePath != nil }
    }

    var snapshot: Snapshot?
    var isRefreshing = false
    var errorMessage: String?

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        Task {
            let result = await Task.detached(priority: .utility) { () -> Snapshot in
                #if arch(arm64)
                let isAppleSilicon = true
                #else
                let isAppleSilicon = false
                #endif

                let supportedSystem = ProcessInfo.processInfo.isOperatingSystemAtLeast(
                    OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
                let selectedXcode: String? = {
                    guard let result = try? ShellRunner.runProcess(
                        executable: "/usr/bin/xcode-select",
                        arguments: ["-p"],
                        workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                        timeout: 15),
                          !result.failed
                    else { return nil }
                    let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
                    return path
                }()
                let identities = (try? AppleDeliverySupport.signingIdentities()) ?? []
                let devices = (try? AppleDeliverySupport.connectedDevices()) ?? []
                return Snapshot(
                    isAppleSilicon: isAppleSilicon,
                    supportedSystem: supportedSystem,
                    xcodePath: selectedXcode,
                    signingIdentityCount: identities.count,
                    connectedDeviceCount: devices.filter { $0.isPhysical && $0.isConnected }.count)
            }.value
            guard !Task.isCancelled else { return }
            snapshot = result
            isRefreshing = false
        }
    }
}

/// A single, non-blocking launch guide. The three rows mirror the actual
/// prerequisites for a useful session and keep optional delivery details
/// subordinate, so first launch feels like a native setup assistant rather
/// than a settings dashboard.
struct WelcomeReadinessView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var readiness = SystemReadinessModel()

    let isOnboarding: Bool
    let onOpenWorkspace: () -> Void
    let onOpenModelManager: () -> Void
    let onComplete: () -> Void

    private var workspaceReady: Bool { appState.sessions.workspaceURL != nil }
    private var agentReady: Bool {
        if appState.isCodexActive || appState.isRemoteActive { return true }
        if case .ready = appState.enginePhase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    essentialCard
                    appleDeliveryCard
                }
                .padding(22)
            }
            footer
        }
        .frame(width: 620, height: 590)
        .background(Theme.bg)
        .task { readiness.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("BeetLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.28), radius: 12, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(isOnboarding ? "Welcome to Beet Code" : "System Readiness")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Open a project, pick a coding model, then describe the task. Signing can wait.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !isOnboarding {
                PanelCloseButton { dismiss() }
            }
        }
        .padding(22)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var essentialCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Start coding", subtitle: "Project folder, then a model. Everything else is optional.")
            readinessRow(
                title: "Project workspace",
                detail: workspaceReady ? appState.sessions.workspaceURL?.path ?? "Ready" : "Choose the folder the agent may work inside.",
                systemImage: "folder.fill",
                ready: workspaceReady,
                actionTitle: workspaceReady ? nil : "Choose Folder",
                action: onOpenWorkspace)
            Divider().padding(.leading, 46)
            readinessRow(
                title: "Coding model",
                detail: agentDetail,
                systemImage: "cpu.fill",
                ready: agentReady,
                actionTitle: agentReady ? nil : "Choose Model",
                action: onOpenModelManager)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 10, y: 3)
    }

    private var appleDeliveryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                sectionTitle("Apple delivery", subtitle: "Build now; add signing or a device when you need them.")
                Spacer()
                Button {
                    readiness.refresh()
                } label: {
                    if readiness.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(LFCapsuleButtonStyle())
                .disabled(readiness.isRefreshing)
                .accessibilityLabel("Refresh Apple delivery readiness")
            }
            readinessRow(
                title: "Mac and Xcode",
                detail: toolchainDetail,
                systemImage: "hammer.fill",
                ready: toolchainReady)
            Divider().padding(.leading, 46)
            readinessRow(
                title: "Signing certificate",
                detail: signingDetail,
                systemImage: "checkmark.seal.fill",
                ready: (readiness.snapshot?.signingIdentityCount ?? 0) > 0,
                optional: true)
            Divider().padding(.leading, 46)
            readinessRow(
                title: "iPhone or iPad",
                detail: deviceDetail,
                systemImage: "iphone",
                ready: (readiness.snapshot?.connectedDeviceCount ?? 0) > 0,
                optional: true)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 10, y: 3)
    }

    private func sectionTitle(_ title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
    }

    private func readinessRow(
        title: LocalizedStringKey,
        detail: String,
        systemImage: String,
        ready: Bool,
        optional: Bool = false,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ready ? Theme.success : optional ? Theme.textTertiary : Theme.warning)
                .frame(width: 32, height: 32)
                .background(Theme.wash(ready ? Theme.success : optional ? Theme.textTertiary : Theme.warning), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    if optional && !ready {
                        Text("OPTIONAL")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
            } else {
                Image(systemName: ready ? "checkmark.circle.fill" : optional ? "minus.circle" : "exclamationmark.circle.fill")
                    .foregroundStyle(ready ? Theme.success : optional ? Theme.textTertiary : Theme.warning)
                    .accessibilityLabel(ready ? "Ready" : optional ? "Optional" : "Needs attention")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if isOnboarding {
                Button("Continue Later") {
                    onComplete()
                    dismiss()
                }
                .buttonStyle(LFCapsuleButtonStyle())
            }
            Spacer()
            Button(workspaceReady && agentReady ? "Start Coding" : "Done") {
                onComplete()
                dismiss()
            }
            .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
            .keyboardShortcut(.defaultAction)
        }
        .padding(18)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var agentDetail: String {
        switch appState.enginePhase {
        case .ready(let name): return "Ready: \(name)"
        case .loading(let name): return "Loading \(name)…"
        case .failed(let reason): return reason
        case .idle:
            if appState.isCodexActive { return "OpenAI Codex is ready." }
            if appState.isRemoteActive { return "Remote provider is ready." }
            return "Use a local Apple Silicon model, Codex, or your own provider."
        }
    }

    private var toolchainReady: Bool {
        guard let snapshot = readiness.snapshot else { return false }
        return snapshot.isAppleSilicon && snapshot.supportedSystem && snapshot.xcodeReady
    }

    private var toolchainDetail: String {
        guard let snapshot = readiness.snapshot else { return "Checking Apple Silicon, macOS, and Xcode…" }
        if !snapshot.isAppleSilicon { return "Beet Code requires an Apple Silicon Mac." }
        if !snapshot.supportedSystem { return "macOS 15 or newer is required." }
        return snapshot.xcodePath.map { "Xcode tools selected at \($0)." }
            ?? "Install Xcode, open it once, then select its command-line tools."
    }

    private var signingDetail: String {
        guard let snapshot = readiness.snapshot else { return "Checking macOS Keychain…" }
        let count = snapshot.signingIdentityCount
        return count == 0
            ? "No valid code-signing identity found yet."
            : "\(count) valid signing \(count == 1 ? "identity" : "identities") in Keychain."
    }

    private var deviceDetail: String {
        guard let snapshot = readiness.snapshot else { return "Looking for connected devices…" }
        let count = snapshot.connectedDeviceCount
        return count == 0 ? "Connect, unlock, and trust a device when you are ready to install." : "\(count) connected physical device\(count == 1 ? "" : "s") ready."
    }
}
