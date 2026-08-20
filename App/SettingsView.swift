import SwiftUI

// MARK: - Settings window

/// Tabbed, card-based settings. Four fixed tabs (General / Agent /
/// Providers / Plugins) instead of one endless scrolling list; every
/// section is a Theme-styled card with an icon header, consistent padding,
/// and a footer that never truncates.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case agent = "Agent"
        case providers = "Providers"
        case plugins = "Plugins"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .agent: "cpu"
            case .providers: "key"
            case .plugins: "puzzlepiece"
            }
        }
    }

    @State private var tab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Spacing.lg)
            .padding(.bottom, Spacing.xs)

            Divider().overlay(Theme.hairline)

            // Plain conditional swap instead of TabView: macOS TabView draws
            // its own tab strip, which would double the segmented picker.
            Group {
                switch tab {
                case .general: GeneralTab()
                case .agent: AgentTab()
                case .providers: ProvidersTab()
                case .plugins: PluginsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .frame(width: 940, height: 720)
    }
}

// MARK: - Shared card chrome

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                content
            }

            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opaque elevated card — matches the main window's surfaces; the
        // translucent lfGlass look is reserved for overlay chrome.
        .lfCard()
    }
}

/// One label-left / control-right row, uniform height and spacing.
private struct SettingRow<Control: View>: View {
    let label: String
    var value: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                if let value {
                    Text(value)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 24)
            control
                .frame(maxWidth: 420, alignment: .trailing)
        }
        .frame(minHeight: 26)
    }
}

/// Boolean setting rendered as a SettingRow — label left, switch right — so
/// every toggle in the window aligns with the picker/stepper rows around it.
/// All settings toggles use the switch style (no mixed checkboxes).
private struct SettingToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(label: label) {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// Accent palette picker rendered as color swatches. Each swatch shows the
/// palette's light-mode accent; selection draws an accent ring. Every swatch
/// carries a tooltip and VoiceOver label naming the palette.
private struct PaletteSwatchPicker: View {
    @Binding var selection: AccentPalette

    var body: some View {
        HStack(spacing: Spacing.md) {
            ForEach(AccentPalette.allCases) { palette in
                swatch(for: palette)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func swatch(for palette: AccentPalette) -> some View {
        let isSelected = palette == selection
        Button {
            selection = palette
        } label: {
            ZStack {
                Circle()
                    .fill(swatchColor(palette))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
                    )
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .lfHoverLift()
        .help(palette.label)
        .accessibilityLabel("\(palette.label) palette")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Static preview color for the swatch — always the palette's light-mode
    /// accent so the picker itself stays readable in either appearance.
    private func swatchColor(_ palette: AccentPalette) -> Color {
        let hex = palette.hexes.accentLight
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

private struct TabScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                content
            }
            .padding(Spacing.lg)
        }
        .background(Theme.bg)
    }
}

/// Slim tinted banner for tab-level explanations — deliberately NOT a
/// SettingsCard, so a one-paragraph note doesn't read as a runt card next
/// to the content-rich cards around it.
private struct InfoBanner: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.info)
                .frame(width: 30, height: 30)
                .background(Theme.washStrong(Theme.info),
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.md)
        .lfWashCard(Theme.info)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var tokenStore = HFTokenStore.shared
    @State private var tokenDraft = ""
    @State private var validationMessage: String?
    @State private var isValidating = false

    var body: some View {
        TabScroll {
            SettingsCard(title: "Composer", icon: "text.cursor", footer: "The composer's signature underline animates through the selected flow's palette; it brightens on focus and during streaming. Turn the animation off for a static gradient.") {
                SettingRow(label: "Style") {
                    Picker("Composer style", selection: $settings.composerFlow) {
                        ForEach(ComposerFlow.allCases) { flow in
                            Text(flow.label).tag(flow)
                        }
                    }
                    .labelsHidden()
                }
                SettingToggle(label: "Animated border", isOn: $settings.composerBorderAnimation)
            }

            SettingsCard(title: "Keyboard", icon: "keyboard", footer: "⌘N starts a new chat, ⌘. stops the agent, ⇧⌘M opens Model Manager. Esc also stops a running agent.") {
                SettingToggle(label: "Enter sends", isOn: $settings.enterSends)
                Text(settings.enterSends
                     ? "Enter sends the message; Shift+Enter inserts a newline. ⌘↩ always sends."
                     : "Enter inserts a newline. Only ⌘↩ sends.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            SettingsCard(title: "Appearance", icon: "paintbrush", footer: "Light is the default. Choose System to follow macOS, or Dark to force dark mode.") {
                SettingRow(label: "Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingRow(label: "Accent palette", value: settings.accentPalette.label) {
                    PaletteSwatchPicker(selection: Binding(
                        get: { settings.accentPalette },
                        set: { settings.accentPalette = $0 }))
                }
            }

            SettingsCard(title: "Launch", icon: "power", footer: "Downloads that were interrupted by quitting resume automatically next launch. When off, they appear paused in the Model Manager for explicit resume.") {
                SettingToggle(label: "Auto-resume interrupted downloads", isOn: Binding(
                    get: { AppPreferencesStore.shared.current.autoResumeDownloads },
                    set: { newValue in
                        var preferences = AppPreferencesStore.shared.current
                        preferences.autoResumeDownloads = newValue
                        AppPreferencesStore.shared.save(preferences)
                    }))
            }

            SettingsCard(title: "Hugging Face", icon: "arrow.down.circle", footer: "Stored in the Keychain, never synced. Required for gated repos; recommended for faster downloads.") {
                SecureField("Access token (hf_…)", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                HStack(spacing: Spacing.sm) {
                    Button("Save") {
                        tokenStore.saveToken(tokenDraft)
                        validationMessage = "Saved to Keychain."
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Validate") {
                        // Validate the DRAFT first; store only after it passes,
                        // so an invalid token is never left in the Keychain.
                        isValidating = true
                        validationMessage = nil
                        Task {
                            defer { isValidating = false }
                            do {
                                let name = try await tokenStore.validate(draft: tokenDraft)
                                tokenStore.saveToken(tokenDraft)
                                validationMessage = "Validated as \(name) — saved."
                            } catch {
                                validationMessage = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isValidating || tokenDraft.isEmpty)

                    if tokenStore.hasToken {
                        Button("Remove", role: .destructive) {
                            tokenStore.deleteToken()
                            tokenDraft = ""
                            validationMessage = "Token removed."
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    if isValidating { ProgressView().controlSize(.small) }
                }
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "Local API Server", icon: "network", footer: "Exposes the loaded model as an OpenAI-compatible endpoint on 127.0.0.1 — loopback only, nothing outside this Mac can reach it. Point Codex (--oss), Claude Code, Aider, or any OpenAI-format client at the base URL. The served model is whatever BeetCode has active; requests carry the full conversation, so the endpoint is stateless.") {
                SettingToggle(label: "Enable local API server", isOn: $settings.apiServerEnabled)
                SettingRow(label: "Port") {
                    TextField("1234", value: $settings.apiServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .monospacedDigit()
                }
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(appState.apiServerRunning ? Theme.success : Theme.textTertiary)
                        .frame(width: 8, height: 8)
                    if appState.apiServerRunning {
                        Text("Serving at \(appState.apiServerBaseURL)")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    } else if let error = appState.apiServerError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    } else {
                        Text("Not running")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Copy curl example") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            """
                            curl \(appState.apiServerBaseURL)/v1/chat/completions \\
                              -H 'Content-Type: application/json' \\
                              -d '{"model":"beetcode","messages":[{"role":"user","content":"Hello"}]}'
                            """,
                            forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.apiServerRunning)
                }
            }

            SettingsCard(title: "Remote Beetcode Sessions", icon: "iphone", footer: "Tailscale is the secure default. Local Wi‑Fi fallback is opt-in for trusted private networks. The QR contains only a short-lived, one-time pairing code; after pairing, the browser receives a scoped token valid for 30 days (or until revoked) and can continue saved Beetcode sessions. It never exposes the terminal CLI or the local model API.") {
                SettingToggle(label: "Enable remote session access", isOn: $settings.remoteSessionEnabled)
                SettingRow(label: "Port") {
                    TextField("9475", value: $settings.remoteSessionPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .monospacedDigit()
                }
                SettingToggle(label: "Allow trusted local-network fallback", isOn: $settings.remoteSessionAllowLAN)
                if settings.remoteSessionAllowLAN {
                    Label("Use this only on a private Wi‑Fi network. Tailscale remains preferred when connected.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(appState.remoteSessionRunning ? Theme.success : Theme.textTertiary)
                        .frame(width: 8, height: 8)
                    if appState.remoteSessionRunning {
                        Text(appState.remoteSessionURL ?? "Remote host ready")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let error = appState.remoteSessionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .lineLimit(2)
                    } else {
                        Text("Not running")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if appState.remoteSessionRunning {
                        Button("Open pairing", systemImage: "iphone") {
                            NotificationCenter.default.post(name: .openRemoteAccess, object: nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .onAppear { tokenDraft = tokenStore.token() ?? "" }
    }
}

// MARK: - Agent tab

private struct AgentTab: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        TabScroll {
            SettingsCard(title: "Autonomy", icon: "shield.lefthalf.filled", footer: "Reads are always automatic. Every write shows a diff preview and asks first unless file edits are auto-approved. Auto-approving commands is a safe-command policy, not a shell bypass: only exact invocations of known read-only executables (swift, xcodebuild, ls, git status, rg, …) with arguments inside the workspace are admitted; shell operators, substitutions, redirections, backgrounding, and any path outside the workspace always require an approval card.") {
                SettingRow(label: "Agent mode", value: settings.agentMode.help) {
                    Picker("Agent mode", selection: $settings.agentMode) {
                        ForEach(AgentMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
                SettingToggle(label: "Auto-approve file edits", isOn: $settings.autoApproveEdits)
                SettingToggle(label: "Auto-approve safe commands", isOn: $settings.autoApproveCommands)
            }

            SettingsCard(title: "Generation", icon: "slider.horizontal.3", footer: "Thermal policy caps these automatically when the Mac gets hot.") {
                SettingRow(label: "Max agent turns") {
                    stepperControl(label: "Max agent turns", value: $settings.maxTurns, range: 5...100, step: 1)
                }
                SettingRow(label: "Max tokens per turn") {
                    stepperControl(label: "Max tokens per turn", value: $settings.maxTokensPerTurn, range: 256...8192, step: 256)
                }
                SettingRow(label: "Temperature") {
                    HStack(spacing: Spacing.sm) {
                        Slider(value: $settings.temperature, in: 0...1.5, step: 0.05)
                            .frame(width: 220)
                        // Fixed-width value label so the slider never reflows.
                        Text(String(format: "%.2f", settings.temperature))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            SettingsCard(title: "Memory & Context", icon: "brain", footer: "Memory stores durable facts and earlier-session summaries per workspace (Mem0/Letta-style) and injects the most relevant ones into the prompt. Compression controls how aggressively old tool outputs are compacted; assistant/tool pairing is always preserved.") {
                SettingRow(label: "Memory") {
                    Picker("Memory", selection: $settings.memoryMode) {
                        ForEach(MemoryMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
                SettingRow(label: "Context compression") {
                    Picker("Context compression", selection: $settings.compressionLevel) {
                        ForEach(CompressionLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .labelsHidden()
                }
                SettingToggle(label: "Plan mode (approve plan before tools run)", isOn: $settings.planMode)
                SettingToggle(label: "Show model reasoning (think blocks)", isOn: $settings.showReasoning)
            }

            SettingsCard(title: "Safety", icon: "checkmark.seal", footer: "Snapshots the working tree before each approved edit batch so any agent action can be undone. Verification runs build diagnostics after each successful edit — through the same approval card as any other command, never silently.") {
                SettingToggle(label: "Git checkpoints before edits", isOn: $settings.checkpointingEnabled)
                SettingToggle(label: "Verify edits with a build", isOn: $settings.verifyAfterEdits)
            }

            ComputerControlCard()
        }
    }

    /// Value + stepper cluster shared by both numeric rows: the current value
    /// stays visible inside the control, right-aligned and monospaced.
    private func stepperControl(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Text("\(value.wrappedValue)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 40, alignment: .trailing)
            Stepper(label, value: value, in: range, step: step)
                .labelsHidden()
        }
    }
}

// MARK: - Computer control permissions

/// Live status of the two TCC permissions computer use needs, with one-tap
/// grant buttons. Status refreshes on appear and after returning to the app
/// (the user flips the switch in System Settings, then comes back).
private struct ComputerControlCard: View {
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false

    var body: some View {
        SettingsCard(
            title: "Computer control",
            icon: "desktopcomputer.and.arrow.down",
            footer: "Lets the agent observe and drive any Mac app (computer_* tools): the accessibility tree and screenshots for observation, mouse/keyboard for actions. Observation is automatic; every click, keystroke, and scroll passes through the approval card. Both permissions are macOS-level and can be revoked anytime in System Settings → Privacy & Security."
        ) {
            permissionRow(
                label: "Accessibility",
                value: "Read app UI trees; post mouse & keyboard events",
                granted: accessibilityGranted,
                grant: { ComputerPermission.requestAccessibility() })
            permissionRow(
                label: "Screen Recording",
                value: "Capture windows for vision models",
                granted: screenRecordingGranted,
                grant: { ComputerPermission.requestScreenRecording() })
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func permissionRow(
        label: String,
        value: String,
        granted: Bool,
        grant: @escaping () -> Void
    ) -> some View {
        SettingRow(label: label, value: value) {
            HStack(spacing: Spacing.sm) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(granted ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(granted ? "Granted" : "Not granted")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !granted {
                    Button("Grant…", action: grant)
                        .controlSize(.small)
                }
            }
        }
    }

    private func refresh() {
        accessibilityGranted = ComputerPermission.accessibilityGranted
        screenRecordingGranted = ComputerPermission.screenRecordingGranted
    }
}

// MARK: - Providers tab

private struct ProvidersTab: View {
    @ObservedObject private var keyStore = APIKeyStore.shared
    /// Keys that survived the LocalForge rename inside the OLD Keychain
    /// services but could not be copied silently (their ACLs demand one
    /// interactive re-authorization). Banner offers the one-tap restore.
    @State private var pendingRestore = false
    @State private var restoreResult: String?

    var body: some View {
        TabScroll {
            if pendingRestore {
                keyRestoreBanner
            }
            // A slim tinted banner, not a SettingsCard: a full card around
            // one paragraph read as a runt next to the provider cards.
            InfoBanner(
                icon: "key",
                text: "Run the agent on a remote model instead of a local download. Keys live in the Keychain only. After saving a key, use **Test** to verify the connection, then activate the provider in the Model Manager.")
            ForEach(LLMProvider.allCases) { provider in
                ProviderCard(provider: provider)
            }
        }
        .task { pendingRestore = LegacyMigration.needsInteractiveKeyMigration() }
        .onReceive(keyStore.objectWillChange) { _ in
            // A restored/saved key may have cleared the pending state.
            pendingRestore = LegacyMigration.needsInteractiveKeyMigration()
        }
    }

    private var keyRestoreBanner: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .frame(width: 30, height: 30)
                .background(Theme.washStrong(Theme.warning),
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Keys from LocalForge found")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Your saved API keys are still in the Keychain under the old LocalForge app, but macOS requires one authorization to move them. Your keys were never deleted.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.md) {
                    Button("Restore Keys…") {
                        restoreKeys()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    if let restoreResult {
                        Text(restoreResult)
                            .font(.caption)
                            .foregroundStyle(Theme.success)
                    }
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lfWashCard(Theme.warning)
    }

    /// Runs the interactive migration OFF the main actor — the Keychain
    /// authorization dialog is system-rendered, but the SecItem calls must
    /// not block SwiftUI while it is up.
    private func restoreKeys() {
        Task.detached(priority: .userInitiated) {
            let migrated = LegacyMigration.migrateInteractively()
            await MainActor.run {
                if migrated > 0 {
                    restoreResult = "Restored \(migrated) key\(migrated == 1 ? "" : "s")."
                    pendingRestore = LegacyMigration.needsInteractiveKeyMigration()
                    keyStore.objectWillChange.send()
                } else {
                    restoreResult = "Nothing restored — approve the Keychain prompt and try again."
                }
            }
        }
    }
}

/// One provider card: key input, model choice, save/test/remove actions and
/// the exact endpoint it talks to — so misconfigured providers (wrong key
/// tier, wrong base URL) are obvious at a glance.
private struct ProviderCard: View {
    let provider: LLMProvider
    @ObservedObject private var keyStore = APIKeyStore.shared
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var baseURDraft = ""
    /// Models fetched live from the provider (P10); merged into the picker.
    @State private var liveModels: [String] = []
    @State private var liveProfiles: [RemoteModelProfile] = []
    @State private var refreshingModels = false
    @State private var modelListError: String?
    @State private var overrideContextWindow = ""
    @State private var overrideOutputTokens = ""
    @State private var overrideVision: CapabilityMode = .automatic
    @State private var overrideTools: CapabilityMode = .automatic
    @State private var overrideReasoning: CapabilityMode = .automatic
    @State private var overrideTemperature: CapabilityMode = .automatic

    private enum CapabilityMode: String, CaseIterable, Identifiable {
        case automatic = "Auto"
        case enabled = "On"
        case disabled = "Off"

        var id: String { rawValue }
        var value: Bool? {
            switch self {
            case .automatic: nil
            case .enabled: true
            case .disabled: false
            }
        }

        init(value: Bool?) {
            switch value {
            case .some(true): self = .enabled
            case .some(false): self = .disabled
            case .none: self = .automatic
            }
        }
    }

    enum TestState: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }
    @State private var testState: TestState = .idle
    @State private var saveMessage: String?

    private var hasKey: Bool { keyStore.hasKey(for: provider) }
    private var keyAvailableForUse: Bool {
        hasKey || !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var endpointLabel: String {
        provider.openAICompatibleBaseURL?.absoluteString
            ?? provider.geminiBaseURL?.absoluteString
            ?? provider.anthropicBaseURL?.absoluteString
            ?? "not configured — set a base URL below"
    }

    /// Custom + local servers run keyless (Ollama/LM Studio); the card must
    /// not gate everything behind an API key for them.
    private var keyless: Bool { provider.keyOptional && !hasKey }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header: provider glyph + name + status badges — the same
            // icon-header chrome every SettingsCard wears.
            HStack(spacing: Spacing.sm) {
                Image(systemName: provider == .custom ? "server.rack" : "cloud.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(provider.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if hasKey || (provider.keyOptional && provider.openAICompatibleBaseURL != nil) {
                    badge("Configured", systemImage: "checkmark.seal.fill", tint: Theme.success)
                }
                if provider.supportsVision {
                    badge("Vision", systemImage: "eye", tint: Theme.info)
                }
                Spacer()
                if hasKey {
                    Button("Remove key", role: .destructive) {
                        keyStore.deleteKey(for: provider)
                        keyDraft = ""
                        testState = .idle
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text(endpointLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Custom provider: base URL first — everything hangs off it.
            if provider == .custom {
                HStack(spacing: Spacing.sm) {
                    TextField("Base URL — e.g. http://127.0.0.1:11434/v1", text: $baseURDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                    Button("Save URL") {
                        var prefs = AppPreferencesStore.shared.current
                        prefs.customBaseURL = baseURDraft.trimmingCharacters(in: .whitespaces)
                        AppPreferencesStore.shared.save(prefs)
                        testState = .idle
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(baseURDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Works with any OpenAI-compatible server: Ollama, LM Studio, vLLM, llama.cpp, Groq, Together, corporate proxies. Key is optional for local servers.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            // Key input
            HStack(spacing: Spacing.sm) {
                SecureField(
                    hasKey ? "API key (replace)" : (keyless ? "API key (optional)" : "API key"),
                    text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Save") {
                    let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let keyForRefresh: String?
                    if !draft.isEmpty {
                        guard keyStore.save(key: draft, for: provider) else {
                            saveMessage = "Could not save this key to the Keychain. Try again or unlock Keychain access."
                            return
                        }
                        keyForRefresh = draft
                    } else {
                        keyForRefresh = resolvedKey.isEmpty ? nil : resolvedKey
                    }
                    if provider == .custom { persistBaseURLDraft() }
                    persistModelDraft()
                    keyDraft = ""
                    saveMessage = draft.isEmpty ? "Settings saved." : "API key saved securely."
                    testState = .idle
                    // Use the just-saved draft directly. A protected or
                    // migrated Keychain item must not make a valid new key
                    // disappear between Save and model discovery.
                    if let keyForRefresh { refreshModels(apiKey: keyForRefresh) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty && modelUnchanged && baseURUnchanged)
            }

            if let credentialHint = provider.credentialHint {
                Label(credentialHint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let saveMessage {
                Label(saveMessage, systemImage: saveMessage.hasPrefix("Could") ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(saveMessage.hasPrefix("Could") ? Theme.danger : Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Model choice — stacked: the picker gets its own full-width row,
            // the free-form model id + actions sit on the row below so
            // neither control fights for width.
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if !modelOptions.isEmpty {
                    SettingRow(label: "Model") {
                        Picker("Model", selection: $modelDraft) {
                            if !liveModels.isEmpty {
                                Section("Live from \(provider.displayName)") {
                                    ForEach(liveModels, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                Section("Common") {
                                    ForEach(provider.suggestedModels.filter { !liveModels.contains($0) }, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                            } else {
                                ForEach(modelOptions, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            if !modelDraft.isEmpty,
                               !liveModels.contains(modelDraft),
                               !provider.suggestedModels.contains(modelDraft) {
                                Section("Selected") {
                                    Text(modelDraft).tag(modelDraft)
                                }
                            }
                        }
                        .labelsHidden()
                    }
                }

                HStack(spacing: Spacing.sm) {
                    TextField("Model id", text: $modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())

                    Button {
                        refreshModels()
                    } label: {
                        if refreshingModels {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Fetch the provider's live model list")
                    .accessibilityLabel("Refresh \(provider.displayName) model list")
                    .disabled(refreshingModels || (!keyAvailableForUse && !provider.keyOptional))

                    Button("Test") { runTest() }
                        .buttonStyle(.bordered)
                        .disabled(testState == .running || (!keyAvailableForUse && !provider.keyOptional))
                }

                if !liveModels.isEmpty {
                    Text("Model list fetched live from \(provider.displayName) — \(liveModels.count) available.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                } else if hasKey || keyless {
                    Text("The list below is a static fallback — press ⟳ to fetch \(provider.displayName)'s current models.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                if let modelListError {
                    Label(modelListError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let profile = selectedProfile {
                    Text(profileSummary(profile))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                modelCapabilitiesEditor
            }

            // Test result — only rendered once a test is underway or done,
            // so an idle card stays compact (no reserved empty line).
            if testState != .idle {
                HStack(spacing: Spacing.xs) {
                    switch testState {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView().controlSize(.mini)
                        Text("Contacting \(provider.displayName)…")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    case .ok(let detail):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.success)
                            .lineLimit(3)
                    case .failed(let detail):
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(Theme.danger)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lfCard()
        .onAppear {
            modelDraft = AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
                ?? provider.defaultModel
            loadModelOverride()
            if provider == .custom {
                baseURDraft = AppPreferencesStore.shared.current.customBaseURL ?? ""
            }
            // Do not probe every provider's protected Keychain item on
            // settings launch. Refresh is explicit, or follows a Save.
        }
        .onChange(of: modelDraft) { _, _ in loadModelOverride() }
    }

    /// Status pill in the card header — washed fill + border from the tint
    /// so badges read identically to the rest of the app's tinted surfaces.
    private func badge(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.wash(tint), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.washBorder(tint), lineWidth: 1))
    }

    /// Suggested models, any saved draft, plus whatever the provider's live
    /// `/models` endpoint returned — static presets go stale fast (P10).
    private var modelOptions: [String] {
        var options = provider.suggestedModels
        for live in liveModels where !options.contains(live) {
            options.append(live)
        }
        if !modelDraft.isEmpty, !options.contains(modelDraft) {
            options.append(modelDraft)
        }
        return options
    }

    private var modelUnchanged: Bool {
        let saved = AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
            ?? provider.defaultModel
        return saved == modelDraft
    }

    private var baseURUnchanged: Bool {
        guard provider == .custom else { return true }
        return (AppPreferencesStore.shared.current.customBaseURL ?? "") == baseURDraft
    }

    private var resolvedKey: String {
        let draft = keyDraft.trimmingCharacters(in: .whitespaces)
        if !draft.isEmpty { return draft }
        return keyStore.key(for: provider) ?? ""
    }

    private func persistBaseURLDraft() {
        let trimmed = baseURDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var prefs = AppPreferencesStore.shared.current
        prefs.customBaseURL = trimmed
        AppPreferencesStore.shared.save(prefs)
    }

    private func persistModelDraft() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var preferences = AppPreferencesStore.shared.current
        preferences.remoteModel[provider.rawValue] = trimmed
        AppPreferencesStore.shared.save(preferences)
    }

    private func refreshModels(apiKey: String? = nil) {
        refreshingModels = true
        modelListError = nil
        let key = apiKey ?? (resolvedKey.isEmpty ? nil : resolvedKey)
        Task {
            do {
                let profiles = try await RemoteLLMClient.fetchModelProfiles(provider: provider, apiKey: key)
                await MainActor.run {
                    liveProfiles = profiles
                    liveModels = profiles.map(\.model)
                    AppPreferencesStore.shared.saveRemoteModelProfiles(profiles)
                    refreshingModels = false
                    if profiles.isEmpty {
                        modelListError = "The provider returned no usable models — type a model id manually or check its account access."
                    }
                }
            } catch {
                await MainActor.run {
                    // Keep the saved/manual model choices usable when a
                    // provider does not implement `/models` or blocks it for
                    // the account tier. Discovery is optional, credentials
                    // are not.
                    refreshingModels = false
                    let detail = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    modelListError = "Model discovery unavailable — you can still enter a model id manually. (\(detail))"
                }
            }
        }
    }

    private var selectedProfile: RemoteModelProfile? {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        let cached = liveProfiles.first(where: { $0.model == model })
            ?? AppPreferencesStore.shared.remoteModelProfile(provider: provider, model: model)
        let base = cached ?? RemoteModelProfile(
            provider: provider,
            model: model,
            supportsVision: provider.supportsVision,
            supportsTools: true,
            supportsTemperature: true)
        return base.applying(AppPreferencesStore.shared.remoteModelOverride(provider: provider, model: model))
    }

    private func profileSummary(_ profile: RemoteModelProfile) -> String {
        var parts: [String] = []
        if let context = profile.contextWindow { parts.append("context \(context.formatted())") }
        if let output = profile.maxOutputTokens { parts.append("output \(output.formatted())") }
        if profile.supportsTools == true { parts.append("tools") }
        if profile.supportsReasoning == true { parts.append("reasoning") }
        if profile.supportsVision == true { parts.append("vision") }
        return parts.isEmpty ? "Model metadata is unknown — use the capability overrides below for unusual gateways." : parts.joined(separator: " · ")
    }

    private var modelCapabilitiesEditor: some View {
        DisclosureGroup("Model capability overrides") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    TextField("Context window", text: $overrideContextWindow)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    TextField("Max output", text: $overrideOutputTokens)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                }
                capabilityPicker("Tools", selection: $overrideTools)
                capabilityPicker("Reasoning", selection: $overrideReasoning)
                capabilityPicker("Vision", selection: $overrideVision)
                capabilityPicker("Temperature", selection: $overrideTemperature)
                HStack {
                    Text("Overrides apply to this provider/model only and never store API keys.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Save overrides") { saveModelOverride() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.top, Spacing.xs)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
    }

    private func capabilityPicker(_ title: String, selection: Binding<CapabilityMode>) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(CapabilityMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func loadModelOverride() {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = AppPreferencesStore.shared.remoteModelOverride(provider: provider, model: model)
        overrideContextWindow = override?.contextWindow.map(String.init) ?? ""
        overrideOutputTokens = override?.maxOutputTokens.map(String.init) ?? ""
        overrideVision = CapabilityMode(value: override?.supportsVision)
        overrideTools = CapabilityMode(value: override?.supportsTools)
        overrideReasoning = CapabilityMode(value: override?.supportsReasoning)
        overrideTemperature = CapabilityMode(value: override?.supportsTemperature)
    }

    private func saveModelOverride() {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        let override = RemoteModelOverride(
            contextWindow: Int(overrideContextWindow.trimmingCharacters(in: .whitespacesAndNewlines)),
            maxOutputTokens: Int(overrideOutputTokens.trimmingCharacters(in: .whitespacesAndNewlines)),
            supportsVision: overrideVision.value,
            supportsTools: overrideTools.value,
            supportsReasoning: overrideReasoning.value,
            supportsTemperature: overrideTemperature.value)
        AppPreferencesStore.shared.saveRemoteModelOverride(override, provider: provider, model: model)
    }

    private func runTest() {
        let key = resolvedKey
        guard !key.isEmpty || provider.keyOptional else {
            testState = .failed("No API key for \(provider.displayName) — paste one above first.")
            return
        }
        let model = modelDraft.trimmingCharacters(in: .whitespaces).isEmpty
            ? provider.defaultModel
            : modelDraft.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            testState = .failed("No model id configured for \(provider.displayName).")
            return
        }
        testState = .running
        Task {
            do {
                let answered = try await RemoteLLMClient.testConnection(
                    provider: provider, apiKey: key, model: model)
                testState = .ok("Connected — answered as \(answered) (\(model))")
            } catch {
                // A valid credential can still be paired with a stale or
                // account-inaccessible model id. Probe the catalog once so
                // the UI distinguishes “key works” from “choose another
                // model” instead of rejecting both as an auth failure.
                if let remoteError = error as? RemoteLLMError,
                   case .badStatus(let code, _) = remoteError,
                   (400..<500).contains(code), !key.isEmpty {
                    if let profiles = try? await RemoteLLMClient.fetchModelProfiles(
                        provider: provider, apiKey: key), !profiles.isEmpty {
                        liveProfiles = profiles
                        liveModels = profiles.map(\.model)
                        AppPreferencesStore.shared.saveRemoteModelProfiles(profiles)
                        testState = .ok("Key accepted. \(model) is unavailable for this account; choose one of the \(profiles.count) available models.")
                        return
                    }
                }
                testState = .failed(testErrorMessage(error))
            }
        }
    }

    private func testErrorMessage(_ error: Error) -> String {
        let fallback = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        guard provider == .gemini,
              let remoteError = error as? RemoteLLMError,
              case .badStatus(let code, let detail) = remoteError,
              [400, 401, 403].contains(code),
              detail.localizedCaseInsensitiveContains("api key")
                || detail.localizedCaseInsensitiveContains("caller")
                || detail.localizedCaseInsensitiveContains("permission")
        else {
            return fallback
        }
        return "Google rejected this credential (HTTP \(code)). Create or copy a Gemini API key from Google AI Studio, or choose the provider that issued this key."
    }
}


// MARK: - Plugins tab

/// Universal compatibility surface: shows which foreign tool conventions
/// Beet Code picked up for the current workspace — Claude skills/commands,
/// Codex prompts, Cursor rule packs, Copilot instructions — and which
/// instruction file the agent actually loads. Read-only: the source of
/// truth stays the files on disk, this tab just makes discovery visible.
private struct PluginsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var commands: [ExternalCommand] = []
    @State private var instructionSource: String?

    var body: some View {
        TabScroll {
            InfoBanner(
                icon: "puzzlepiece.extension",
                text: "Beet Code reads the convention directories of Claude Code, Codex, Cursor and Copilot, so the skills, commands, prompts and project rules you already have keep working here. Discovered skills and commands become slash commands in the composer — type /help to see them.")

            SettingsCard(
                title: "Project instructions",
                icon: "doc.text.magnifyingglass",
                footer: "Search order: AGENTS.md → CLAUDE.md → .cursor/rules → .cursorrules → .github/copilot-instructions.md — workspace first, then user-level (~/.beetcode, ~/.claude). The first file found wins.") {
                SettingRow(
                    label: instructionSource ?? "No instructions file found",
                    value: appState.sessions.workspaceURL?.path ?? "Open a workspace folder to load project rules") {
                    Image(systemName: instructionSource == nil ? "circle.dashed" : "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(instructionSource == nil ? Theme.textTertiary : Theme.success)
                }
            }

            SettingsCard(
                title: "Slash commands",
                icon: "slash.circle",
                footer: "Scanned: .claude/skills/<name>/SKILL.md, .claude/commands/*.md, .codex/prompts/*.md, .beetcode/commands/*.md — in the workspace first, then your home folder; the workspace wins name collisions. MCP server config import (~/.claude.json, .cursor/mcp.json, ~/.codex/config.toml) is not supported yet.") {
                if commands.isEmpty {
                    Text("No external commands discovered yet.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(grouped, id: \.0) { origin, items in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(origin)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textTertiary)
                            ForEach(items) { command in
                                SettingRow(
                                    label: "/\(command.name)",
                                    value: command.location.path) {
                                    Text(command.kind.label)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Theme.wash(Theme.accent), in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    /// Commands grouped by origin, in a stable Claude → Codex → BeetCode
    /// order so the list doesn't reshuffle between scans.
    private var grouped: [(String, [ExternalCommand])] {
        let order: [ExternalCommand.Origin] = [.claude, .codex, .beetcode]
        return order.compactMap { origin in
            let items = commands.filter { $0.origin == origin }
            return items.isEmpty ? nil : (origin.rawValue, items)
        }
    }

    private func reload() {
        let workspace = appState.sessions.workspaceURL
        commands = ExternalCommands.discover(
            home: FileManager.default.homeDirectoryForCurrentUser,
            workspace: workspace)
        instructionSource = workspace.flatMap { ProjectInstructions.load(workspaceRoot: $0)?.source }
    }
}
