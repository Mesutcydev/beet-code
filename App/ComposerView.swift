import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Composer

/// The composer: BeetCode's single input surface. One elevated card holding
/// the editor and the accessory row; above it, the per-turn Intent chips and
/// attachment chips appear only when they exist.
///
/// Design contract:
/// - No layout shift — intent editing lives in a popover anchored to the
///   Intent button; the card never moves.
/// - Enter sends, Shift+Enter inserts a newline, ⌘↩ sends too, Esc stops a
///   running agent (the only `.cancelAction` owner in the window).
/// - Send morphs into Stop while the agent runs.
/// - A restrained state border tracks idle → focused → streaming.
struct ComposerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var store: ComposerStore

    @FocusState private var editorFocused: Bool
    @State private var isDropTargeted = false

    private var phase: ComposerPhase {
        if controller.pendingApproval != nil
            || controller.pendingPlan != nil
            || controller.pendingQuestion != nil {
            return .awaitingApproval
        }
        if controller.isRunning { return .streaming }
        return editorFocused ? .focused : .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            card
            if let hint = blockingHint {
                hintRow(hint)
            }
        }
        // The same centered column as the transcript above, so the input
        // sits directly under the conversation it belongs to.
        .frame(maxWidth: ContentColumn.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.bg)
        .onReceive(NotificationCenter.default.publisher(for: .sendMessage)) { _ in
            store.send()
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            ComposerHeader(
                store: store,
                focusEditor: { editorFocused = true },
                editor: editor)

            if !store.selection.isEmpty || !store.attachments.isEmpty {
                ComposerDraftContext(store: store)
                    .padding(.bottom, Spacing.md)
            }

            HStack(alignment: .center, spacing: Spacing.sm) {
                AccessoryRow(store: store)
                    .environmentObject(appState)
                    .environmentObject(controller)

                Spacer(minLength: Spacing.sm)

                ContextMeter(
                    estimate: store.estimate,
                    canCompact: store.canCompactHistory,
                    compact: { controller.compactNow() })

                SendStopButton(store: store)
            }
        }
        .padding(14)
        .modifier(ComposerBorder(
            flow: settings.composerFlow,
            phase: phase,
            animated: settings.composerBorderAnimation && !reduceMotion))
        .overlay {
            if isDropTargeted {
                ComposerDropOverlay()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            acceptDroppedFiles(from: providers)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isDropTargeted)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The editor is the primary surface; status already lives in the chat
    /// header, so the composer does not repeat it.
    private struct ComposerHeader<Editor: View>: View {
        let store: ComposerStore
        let focusEditor: () -> Void
        let editor: Editor

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                editor
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                ComposerCommandMenu(store: store) {
                    focusEditor()
                }
            }
            .padding(.bottom, Spacing.md)
        }
    }

    private var editor: some View {
        TextField(composerPlaceholder, text: Bindable(store).prompt, axis: .vertical)
            .textFieldStyle(.plain)
            .font(AppFont.editor)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...8)
            .frame(minHeight: 38, alignment: .topLeading)
            .focused($editorFocused)
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
            // Enter sends; Shift+Enter falls through to the field and
            // inserts a newline.
            .onKeyPress(phases: .down) { press in
                if ShortcutBinding(rawValue: SettingsStore.shared.sendShortcut).matches(press) {
                    return store.send() ? .handled : .ignored
                }
                if press.key == .return && press.modifiers.contains(.command) {
                    return store.send() ? .handled : .ignored
                }
                let newlineModifiers: EventModifiers = [.shift, .option, .control]
                if press.key == .return,
                   settings.enterSends,
                   press.modifiers.intersection(newlineModifiers).isEmpty {
                    return store.send() ? .handled : .ignored
                }
                return .ignored
            }
            // Esc stops the agent while it runs; otherwise the key belongs
            // to whatever else wants it.
            .onKeyPress(.escape) {
                if controller.isRunning {
                    controller.stop()
                    return .handled
                }
                return .ignored
            }
            .accessibilityLabel("Task description")
    }

    private var composerPlaceholder: LocalizedStringKey {
        controller.workspaceURL == nil
            ? "Message Beet Code…"
            : "Ask Beet Code to build, fix, or explain…"
    }

    private func acceptDroppedFiles(from providers: [NSItemProvider]) -> Bool {
        let candidates = providers
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            .prefix(max(0, 8 - store.attachments.count))
        guard !candidates.isEmpty else { return false }

        for provider in candidates {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    store.addAttachments([url])
                }
            }
        }
        return true
    }

    // MARK: Blocking hint

    /// Shown only when the user has something to send but can't — never a
    /// nag on an empty composer.
    private var blockingHint: String? {
        guard !controller.isRunning,
              !store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let blocker = store.sendBlocker,
              blocker != "Describe the task first"
        else { return nil }
        return blocker
    }

    private func hintRow(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.warning)
            Text(text)
                .foregroundStyle(Theme.warning)
            if text.contains("model") {
                Button("Open Model Manager") {
                    NotificationCenter.default.post(name: .openModelManager, object: nil)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }
}

// MARK: - Draft context

/// Attachments and turn guidance stay inside the writing surface, where they
/// read as part of the outgoing message instead of as a second toolbar.
private struct ComposerDraftContext: View {
    let store: ComposerStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(store.attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        store.attachments.removeAll { $0.id == attachment.id }
                    }
                }

                ForEach(store.selection.orderedRoles) { role in
                    ComposerIntentChip(
                        label: role.label,
                        glyph: role.glyph,
                        tint: Theme.accent,
                        help: role.instruction) {
                        store.toggleRole(role)
                    }
                }

                ForEach(store.selection.orderedFocus) { source in
                    ComposerIntentChip(
                        label: source.label,
                        glyph: source.glyph,
                        tint: Theme.info,
                        help: source.summary) {
                        store.toggleFocus(source)
                    }
                }

                if !store.selection.isEmpty {
                    Button("Clear context") {
                        store.clearIntent()
                    }
                    .font(.caption2.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Remove all roles and context sources")
                }
            }
            .padding(.horizontal, 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached files and turn context")
    }
}

private struct ComposerIntentChip: View {
    let label: String
    let glyph: String
    let tint: Color
    let help: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: glyph)
                .font(.caption2.weight(.medium))
            Text(label)
                .font(.caption.weight(.medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
        }
        .foregroundStyle(tint)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(minHeight: 26)
        .background(Theme.wash(tint), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.washBorder(tint), lineWidth: 1))
        .help(help)
    }
}

private struct ComposerDropOverlay: View {
    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 20, weight: .semibold))
            Text("Drop files to attach")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Composer header

/// A deliberate command-deck affordance for the actions that are useful
/// before typing. It is a real Menu, not a visual flourish: presets, focus,
/// and draft clearing all operate on the same ComposerStore as the visible
/// controls below.
private struct ComposerCommandMenu: View {
    @EnvironmentObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showsDeliverySetup = false

    let store: ComposerStore
    let focusEditor: () -> Void

    var body: some View {
        Menu {
            Button {
                focusEditor()
            } label: {
                Label("Focus prompt", systemImage: "text.cursor")
            }

            if controller.workspaceURL != nil {
                Menu("Use a guidance preset") {
                    ForEach(IntentPresets.all) { preset in
                        Button {
                            store.applyPreset(preset)
                        } label: {
                            Label(preset.name, systemImage: preset.glyph)
                        }
                    }
                }

                Menu("Start an Apple app") {
                    Button {
                        prepareAppleAppPrompt(platform: "iPhone and iPad")
                    } label: {
                        Label("iPhone & iPad app", systemImage: "iphone.and.arrow.forward")
                    }

                    Button {
                        prepareAppleAppPrompt(platform: "macOS")
                    } label: {
                        Label("Mac app", systemImage: "macwindow")
                    }
                }

                Button {
                    prepareShipPrompt()
                } label: {
                    Label("Ship current Apple app", systemImage: "shippingbox")
                }

                Button {
                    showsDeliverySetup = true
                } label: {
                    Label("Sign & install on device…", systemImage: "checkmark.shield")
                }

                Divider()
            }

            Toggle(isOn: Binding(
                get: { settings.showReasoning },
                set: { settings.showReasoning = $0 }
            )) {
                Label("Show reasoning details", systemImage: "brain.head.profile")
            }

            Divider()

            Button("Clear prompt") {
                store.prompt = ""
            }
            .disabled(store.prompt.isEmpty)

            Button("Clear turn setup") {
                store.clearIntent()
                store.attachments = []
            }
            .disabled(store.selection.isEmpty && store.attachments.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceInset.opacity(0.44), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .lfHoverLift()
        .help("Open composer commands and guidance presets")
        .accessibilityLabel("Composer commands")
        .sheet(isPresented: $showsDeliverySetup) {
            AppleDeliverySetupView { prompt in
                settings.agentMode = .goal
                if let preset = IntentPresets.preset(id: "full-pipeline") {
                    store.applyPreset(preset)
                }
                store.prompt = prompt
                showsDeliverySetup = false
                focusEditor()
            }
        }
    }

    private func prepareAppleAppPrompt(platform: String) {
        settings.agentMode = .goal
        if let preset = IntentPresets.preset(id: "full-pipeline") {
            store.applyPreset(preset)
        }
        store.prompt = """
        Build and deliver a polished native \(platform) app from this workspace. Start by clarifying only decisions that materially affect the product, then implement it in SwiftUI, build it, run it, inspect the result, fix issues, and verify the finished app end to end.
        """
        focusEditor()
    }

    private func prepareShipPrompt() {
        settings.agentMode = .goal
        if let preset = IntentPresets.preset(id: "full-pipeline") {
            store.applyPreset(preset)
        }
        store.prompt = """
        Prepare the current Apple app for delivery. Inspect the project and its changes, run the relevant end-to-end checks, launch and visually verify the app, repair any issues, then use apple_ship to create a Release artifact, checksum, logs, and Ship Report. Do not enable signing unless I explicitly request it.
        """
        focusEditor()
    }
}

// MARK: - Signing & device delivery

/// A focused setup sheet for the one Apple workflow that should never require
/// users to remember Xcode flags. Private keys stay in Keychain; the composer
/// receives only the selected certificate fingerprint and delivery choices.
private struct AppleDeliverySetupView: View {
    @Environment(\.dismiss) private var dismiss

    let onPrepare: (String) -> Void

    @State private var identities: [AppleSigningIdentity] = []
    @State private var devices: [AppleConnectedDevice] = []
    @State private var selectedIdentity = ""
    @State private var selectedDevice = ""
    @State private var exportMethod = "debugging"
    @State private var teamID = ""
    @State private var profile = ""
    @State private var letsXcodeManageProfiles = true
    @State private var installsAfterSigning = true
    @State private var uploadsToAppStoreConnect = false
    @State private var isLoading = true
    @State private var importHint: String?

    private var currentIdentity: AppleSigningIdentity? {
        identities.first { $0.fingerprint == selectedIdentity }
    }

    private var connectedDevices: [AppleConnectedDevice] {
        devices.filter { $0.isPhysical && $0.isConnected }
    }

    private var canPrepare: Bool {
        !selectedIdentity.isEmpty
            && (!installsAfterSigning || !selectedDevice.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    identitySection
                    deliverySection
                    advancedSection
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.lg)
            }

            footer
        }
        .frame(width: 580, height: 570)
        .background(Theme.bg)
        .task { await reload() }
        .onChange(of: exportMethod) { _, method in
            if method == "app-store-connect" {
                installsAfterSigning = false
                uploadsToAppStoreConnect = true
            } else {
                uploadsToAppStoreConnect = false
            }
        }
        .onChange(of: installsAfterSigning) { _, enabled in
            if enabled, selectedDevice.isEmpty {
                selectedDevice = connectedDevices.first?.id ?? ""
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.washStrong(Theme.accent), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Signing & Device Delivery")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Build a signed iPhone or iPad app with credentials already on this Mac.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var identitySection: some View {
        setupCard(title: "Signing certificate", icon: "person.badge.key") {
            if isLoading {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Checking Keychain…")
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if identities.isEmpty {
                Label("No valid Apple signing certificate was found.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
            } else {
                Picker("Certificate", selection: $selectedIdentity) {
                    ForEach(identities) { identity in
                        Text(identity.name).tag(identity.fingerprint)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                if let identity = currentIdentity {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text(identity.teamID.map { "Valid · Team \($0)" } ?? "Valid in macOS Keychain")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: Spacing.sm) {
                Button("Import certificate…", systemImage: "square.and.arrow.down") {
                    importCertificate()
                }
                .buttonStyle(LFCapsuleButtonStyle())

                Button("Rescan", systemImage: "arrow.clockwise") {
                    Task { await reload() }
                }
                .buttonStyle(LFCapsuleButtonStyle())
                .disabled(isLoading)
            }

            if let importHint {
                Text(importHint)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Label("Beet Code never reads, copies, or stores your private key or certificate password.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var deliverySection: some View {
        setupCard(title: "Delivery", icon: "iphone.and.arrow.forward") {
            Picker("Build for", selection: $exportMethod) {
                Text("Development").tag("debugging")
                Text("Ad Hoc testing").tag("release-testing")
                Text("App Store Connect").tag("app-store-connect")
                Text("Enterprise").tag("enterprise")
            }
            .pickerStyle(.segmented)

            Toggle("Let Xcode manage provisioning profiles", isOn: $letsXcodeManageProfiles)
                .toggleStyle(.switch)

            Toggle("Install after signing", isOn: $installsAfterSigning)
                .toggleStyle(.switch)
                .disabled(exportMethod == "app-store-connect")

            if exportMethod == "app-store-connect" {
                Toggle("Upload to App Store Connect after validation", isOn: $uploadsToAppStoreConnect)
                    .toggleStyle(.switch)
                Text("Xcode uses the developer account already configured on this Mac and records the upload result in the Ship Report.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            if installsAfterSigning {
                if connectedDevices.isEmpty {
                    Label {
                        Text("Connect and unlock an iPhone or iPad, trust this Mac, and enable Developer Mode.")
                    } icon: {
                        Image(systemName: "cable.connector")
                    }
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                } else {
                    Picker("Device", selection: $selectedDevice) {
                        ForEach(connectedDevices) { device in
                            Text("\(device.name) · \(device.model)").tag(device.id)
                        }
                    }
                }
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                TextField("Developer Team ID (optional)", text: $teamID)
                    .textFieldStyle(.roundedBorder)
                TextField("Provisioning profile name or UUID (optional)", text: $profile)
                    .textFieldStyle(.roundedBorder)
                Text("Leave these blank to use the team embedded in the selected certificate and the project’s signing settings.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, Spacing.sm)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
    }

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            Button("Cancel") { dismiss() }
                .buttonStyle(LFCapsuleButtonStyle())
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Add to composer", systemImage: "arrow.right") {
                onPrepare(preparedPrompt)
            }
            .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(!canPrepare)
            .help(canPrepare ? "Prepare the signed delivery task" : prepareBlocker)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private func setupCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            content()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private var prepareBlocker: String {
        if selectedIdentity.isEmpty { return "Import or select a valid signing certificate" }
        return "Connect and select a physical device, or turn off Install after signing"
    }

    private var preparedPrompt: String {
        let identity = currentIdentity
        let trimmedTeam = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTeam = trimmedTeam.isEmpty ? identity?.teamID : trimmedTeam
        let resolvedProfile: String? = trimmedProfile.isEmpty ? nil : trimmedProfile
        var options = [
            "platform: ios",
            "allowSigning: true",
            "signingIdentity: \(selectedIdentity)",
            "exportMethod: \(exportMethod)",
            "allowProvisioningUpdates: \(letsXcodeManageProfiles)"
        ]
        if let resolvedTeam { options.append("developmentTeam: \(resolvedTeam)") }
        if let resolvedProfile { options.append("provisioningProfile: \(resolvedProfile)") }
        if installsAfterSigning { options.append("installDevice: \(selectedDevice)") }
        if uploadsToAppStoreConnect { options.append("uploadToAppStoreConnect: true") }

        return """
        Prepare the current iPhone or iPad app for delivery. Inspect and test the project, fix any blocking issues, then use apple_ship with these settings:

        \(options.map { "- \($0)" }.joined(separator: "\n"))

        Build a Release archive, complete the selected delivery path, verify the result, and report the artifact, checksum, signing status, App Store upload, and device installation result as applicable. Keep all credentials in macOS Keychain and never request or print certificate passwords.
        """
    }

    @MainActor
    private func reload() async {
        isLoading = true
        let result = await Task.detached(priority: .utility) {
            let identities = (try? AppleDeliverySupport.signingIdentities()) ?? []
            let devices = (try? AppleDeliverySupport.connectedDevices()) ?? []
            return (identities, devices)
        }.value
        identities = result.0
        devices = result.1
        if !identities.contains(where: { $0.fingerprint == selectedIdentity }) {
            selectedIdentity = identities.first?.fingerprint ?? ""
        }
        if teamID.isEmpty {
            teamID = identities.first(where: { $0.fingerprint == selectedIdentity })?.teamID ?? ""
        }
        if !connectedDevices.contains(where: { $0.id == selectedDevice }) {
            selectedDevice = connectedDevices.first?.id ?? ""
        }
        isLoading = false
    }

    private func importCertificate() {
        let panel = NSOpenPanel()
        panel.title = "Import Apple Signing Certificate"
        panel.message = "Choose a .p12 or .pfx certificate. macOS Keychain Access will securely ask for its password."
        panel.prompt = "Open in Keychain Access"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "p12") ?? .data,
            UTType(filenameExtension: "pfx") ?? .data
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        NSWorkspace.shared.open(url)
        importHint = "Finish the import in Keychain Access, then choose Rescan."
    }
}

// MARK: - Accessory row

/// The lower rail exposes only the common choices. Mode, profile, and planning
/// remain available in one setup menu instead of competing as separate chips.
private struct AccessoryRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AgentSessionController

    let store: ComposerStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                AttachChip(store: store)
                ModelSelectionPill()
                    .environmentObject(appState)
                if controller.workspaceURL == nil {
                    Label("Chat only", systemImage: "bubble.left.and.bubble.right")
                        .lfComposerPill(active: true)
                        .help("No project tools are available until you open a folder")
                        .accessibilityLabel("Chat only mode")
                } else {
                    IntentChipButton(store: store)
                    AgentSetupMenu()
                        .environmentObject(appState)
                        .environmentObject(controller)
                }
            }
            .padding(.trailing, 2)
        }
        .frame(minHeight: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Paperclip pill — opens the file picker and appends attachments.
private struct AttachChip: View {
    let store: ComposerStore

    var body: some View {
        Button {
            attachFiles()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .background(Theme.surfaceInset.opacity(0.44), in: Circle())
        }
        .buttonStyle(LFPlainPressButtonStyle())
        .lfHoverLift()
        .help("Attach files or images — files are quoted into the message, images are described by the vision provider")
        .accessibilityLabel("Attach files")
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach files or images"
        panel.message = "Files are quoted into the message; images are described by the vision provider."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            store.addAttachments(panel.urls)
        }
    }
}

// MARK: - Intent chip button

/// Opens the intent popover. Shows the live selection count and lights up
/// while any intent is selected or the popover is open.
private struct IntentChipButton: View {
    let store: ComposerStore
    @State private var showPicker = false

    var body: some View {
        let count = store.selection.count
        let active = count > 0 || showPicker
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .medium))
                Text("Context")
                if count > 0 {
                    // A plain accent count — no badge-in-badge capsule.
                    Text("\(count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
            }
            .lfComposerPill(active: active)
        }
        .buttonStyle(LFPlainPressButtonStyle())
        .help("Choose roles and workspace context for this turn")
        .accessibilityLabel("Turn context")
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            IntentPicker(store: store)
        }
    }
}

/// One calm entry point for execution mode, agent profile, and plan mode.
private struct AgentSetupMenu: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared

    private var selected: OpenCodeCompatibility.AgentProfile? {
        appState.openCodeCatalog.agent(named: controller.selectedOpenCodeAgentName)
    }

    var body: some View {
        Menu {
            Section("Run mode") {
            ForEach(AgentMode.allCases) { mode in
                Button {
                    settings.agentMode = mode
                } label: {
                    Label {
                        Text(mode.label)
                    } icon: {
                        Image(systemName: mode == settings.agentMode ? "checkmark" : mode.icon)
                    }
                }
                .help(mode.help)
            }
            }

            Section("Agent") {
                ForEach(appState.openCodeCatalog.agents.filter(\.visibleInPicker)) { agent in
                    Button {
                        controller.selectedOpenCodeAgentName = agent.name
                        if agent.name.caseInsensitiveCompare("plan") == .orderedSame {
                            settings.planMode = true
                        }
                    } label: {
                        Label {
                            Text(agent.name.capitalized)
                        } icon: {
                            Image(systemName: agent.name == controller.selectedOpenCodeAgentName
                                ? "checkmark"
                                : agent.name.caseInsensitiveCompare("plan") == .orderedSame
                                    ? "list.bullet.clipboard"
                                    : "hammer.fill")
                        }
                    }
                }
            }

            Divider()

            Button {
                settings.planMode.toggle()
            } label: {
                Label("Plan before running",
                      systemImage: settings.planMode ? "checkmark.square.fill" : "square")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: settings.agentMode.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(settings.agentMode.label)
                if settings.planMode {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.caption2.weight(.semibold))
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lfComposerPill(active: settings.planMode)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(selected?.description ?? "Agent setup")
        .accessibilityLabel("Agent setup")
        .accessibilityValue("\(settings.agentMode.label), \(selected?.name.capitalized ?? "Build")\(settings.planMode ? ", plan on" : "")")
    }
}

// MARK: - Estimate (honest telemetry)

private struct ContextMeter: View {
    let estimate: ComposerStore.TokenEstimate
    let canCompact: Bool
    let compact: () -> Void

    var body: some View {
        Group {
            if estimate.requestTokens > 0 {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(text)
                        .foregroundStyle(tint)
                    if estimate.shouldCompact && canCompact {
                        Button(action: compact) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tint)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Compact older tool output before the next run")
                        .accessibilityLabel("Compact conversation context")
                    }
                }
                .help(helpText)
            }
        }
        .font(.caption2.monospacedDigit())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var text: String {
        var text = "≈\(estimate.requestTokens.formatted()) tok"
        if let utilization = estimate.utilization, estimate.contextWindow != nil {
            text += " · \(max(1, Int((utilization * 100).rounded())))%"
        }
        return text
    }

    private var icon: String {
        if estimate.isOverBudget { return "exclamationmark.triangle.fill" }
        if estimate.shouldCompact { return "gauge.with.dots.needle.67percent" }
        return "gauge.with.dots.needle.33percent"
    }

    private var tint: Color {
        guard let utilization = estimate.utilization else { return Theme.textTertiary }
        if utilization >= 1 { return Theme.danger }
        if utilization >= 0.75 { return Theme.warning }
        if utilization >= 0.5 { return Theme.warning }
        return Theme.textTertiary
    }

    private var helpText: String {
        let parts = [
            "draft ≈\(estimate.draftTokens)",
            "intent ≈\(estimate.intentTokens)",
            "focus ≈\(estimate.focusTokens)",
            "attachments ≈\(estimate.attachmentTokens)",
        ]
        let breakdown = parts.joined(separator: " · ")
        if let window = estimate.contextWindow {
            let budget = max(1, window - estimate.responseReserve)
            let history = estimate.historyMessageCount == 0
                ? "no saved history"
                : "\(estimate.historyMessageCount) saved messages"
            return "Estimated request: ≈\(estimate.requestTokens.formatted()) tokens (current turn ≈\(estimate.totalTokens.formatted()), \(history)). Response reserve: \(estimate.responseReserve.formatted()). Safe request budget: \(budget.formatted()). System prompt and tool envelope add additional overhead."
        }
        return "Estimated current turn: \(breakdown). No percentage — this remote model's context window is unknown."
    }
}

// MARK: - Send / stop

/// Send morphs into Stop while the agent runs; the only `.cancelAction`
/// owner in the window, so Esc never conflicts.
private struct SendStopButton: View {
    @EnvironmentObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared
    let store: ComposerStore

    var body: some View {
        Group {
            if controller.isRunning {
                stopButton
            } else {
                sendButton
            }
        }
        .frame(width: 38, height: 38)
    }

    private var stopButton: some View {
        Button {
            controller.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.caption2.weight(.bold))
        }
        .buttonStyle(LFIconButtonStyle(tone: .destructive, size: 38))
        .lfHoverLift()
        .keyboardShortcut(.cancelAction)
        .help("Stop the agent (Esc)")
        .accessibilityLabel("Stop the agent")
    }

    private var sendButton: some View {
        Button {
            store.send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
        }
        .buttonStyle(LFIconButtonStyle(tone: .primary, size: 38))
        .lfHoverLift()
        .disabled(!store.canSend)
        .help(store.canSend
              ? "Send (\(ShortcutBinding(rawValue: settings.sendShortcut).displayValue))"
              : store.sendBlocker ?? "Cannot send")
        .accessibilityLabel("Send")
    }
}

// MARK: - Attachment chip

/// A removable attachment chip above the composer.
struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.isImage ? "photo" : "doc.text")
                .font(.caption)
            Text(attachment.name)
                .font(.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(minHeight: 26)
        .background(Theme.surfaceInset, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .lfHoverLift()
    }
}
