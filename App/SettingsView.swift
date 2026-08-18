import SwiftUI

// MARK: - Settings window

/// Tabbed, card-based settings. Three fixed tabs (General / Agent /
/// Providers) instead of one endless scrolling list; every section is a
/// Theme-styled card with an icon header, consistent padding, and a footer
/// that never truncates.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case agent = "Agent"
        case providers = "Providers"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .agent: "cpu"
            case .providers: "key"
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
            .padding(16)
            .padding(.bottom, 4)

            Divider().overlay(Theme.hairline)

            // Plain conditional swap instead of TabView: macOS TabView draws
            // its own tab strip, which would double the segmented picker.
            Group {
                switch tab {
                case .general: GeneralTab()
                case .agent: AgentTab()
                case .providers: ProvidersTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .frame(width: 780, height: 620)
    }
}

// MARK: - Shared card chrome

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lfGlass()
    }
}

/// One label-left / control-right row, uniform height and spacing.
private struct SettingRow<Control: View>: View {
    let label: String
    var value: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
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
                .frame(maxWidth: 320, alignment: .trailing)
        }
        .frame(minHeight: 26)
    }
}

private struct TabScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                content
            }
            .padding(16)
        }
        .background(Theme.bg)
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
                Toggle("Animated border", isOn: $settings.composerBorderAnimation)
            }

            SettingsCard(title: "Appearance", icon: "paintbrush", footer: "Light is the default. Choose System to follow macOS, or Dark to force dark mode.") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SettingsCard(title: "Launch", icon: "power", footer: "Downloads that were interrupted by quitting resume automatically next launch. When off, they appear paused in the Model Manager for explicit resume.") {
                Toggle("Auto-resume interrupted downloads", isOn: Binding(
                    get: { AppPreferencesStore.shared.current.autoResumeDownloads },
                    set: { newValue in
                        var preferences = AppPreferencesStore.shared.current
                        preferences.autoResumeDownloads = newValue
                        AppPreferencesStore.shared.save(preferences)
                    }))
                .toggleStyle(.switch)
            }

            SettingsCard(title: "Hugging Face", icon: "arrow.down.circle", footer: "Stored in the Keychain, never synced. Required for gated repos; recommended for faster downloads.") {
                SecureField("Access token (hf_…)", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                HStack(spacing: 8) {
                    Button("Save") {
                        tokenStore.saveToken(tokenDraft)
                        validationMessage = "Saved to Keychain."
                    }
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
                    .disabled(isValidating || tokenDraft.isEmpty)

                    if tokenStore.hasToken {
                        Button("Remove", role: .destructive) {
                            tokenStore.deleteToken()
                            tokenDraft = ""
                            validationMessage = "Token removed."
                        }
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
                Toggle("Enable local API server", isOn: $settings.apiServerEnabled)
                    .toggleStyle(.switch)
                SettingRow(label: "Port") {
                    TextField("1234", value: $settings.apiServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.apiServerRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    if appState.apiServerRunning {
                        Text("Serving at \(appState.apiServerBaseURL)")
                            .font(.caption.monospaced())
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
                    .controlSize(.small)
                    .disabled(!appState.apiServerRunning)
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
                Toggle("Auto-approve file edits", isOn: $settings.autoApproveEdits)
                Toggle("Auto-approve safe commands", isOn: $settings.autoApproveCommands)
            }

            SettingsCard(title: "Generation", icon: "slider.horizontal.3", footer: "Thermal policy caps these automatically when the Mac gets hot.") {
                SettingRow(label: "Max agent turns", value: "\(settings.maxTurns)") {
                    Stepper("Max agent turns", value: $settings.maxTurns, in: 5...100)
                        .labelsHidden()
                }
                SettingRow(label: "Max tokens per turn", value: "\(settings.maxTokensPerTurn)") {
                    Stepper("Max tokens per turn", value: $settings.maxTokensPerTurn, in: 256...8192, step: 256)
                        .labelsHidden()
                }
                SettingRow(label: "Temperature", value: String(format: "%.2f", settings.temperature)) {
                    Slider(value: $settings.temperature, in: 0...1.5, step: 0.05)
                        .frame(width: 240)
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
                Toggle("Plan mode (approve plan before tools run)", isOn: $settings.planMode)
                Toggle("Show model reasoning (think blocks)", isOn: $settings.showReasoning)
            }

            SettingsCard(title: "Safety", icon: "checkmark.seal", footer: "Snapshots the working tree before each approved edit batch so any agent action can be undone. Verification runs build diagnostics after each successful edit — through the same approval card as any other command, never silently.") {
                Toggle("Git checkpoints before edits", isOn: $settings.checkpointingEnabled)
                Toggle("Verify edits with a build", isOn: $settings.verifyAfterEdits)
            }
        }
    }
}

// MARK: - Providers tab

private struct ProvidersTab: View {
    var body: some View {
        TabScroll {
            SettingsCard(title: "Bring your own key", icon: "info.circle") {
                Text("Run the agent on a remote model instead of a local download. Keys live in the Keychain only. After saving a key, use **Test** to verify the connection, then activate the provider in the Model Manager.")
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(LLMProvider.allCases) { provider in
                ProviderCard(provider: provider)
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

    enum TestState: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }
    @State private var testState: TestState = .idle

    private var hasKey: Bool { keyStore.key(for: provider) != nil }

    private var endpointLabel: String {
        provider.openAICompatibleBaseURL?.absoluteString
            ?? provider.geminiBaseURL?.absoluteString
            ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: name + status badges
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if hasKey {
                    Label("Configured", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.success)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.success.opacity(0.12)))
                }
                if provider.supportsVision {
                    Label("Vision", systemImage: "eye")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.info)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.info.opacity(0.12)))
                }
                Spacer()
                if hasKey {
                    Button("Remove key", role: .destructive) {
                        keyStore.deleteKey(for: provider)
                        keyDraft = ""
                        testState = .idle
                    }
                    .controlSize(.small)
                }
            }

            Text(endpointLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Key input
            HStack(spacing: 8) {
                SecureField(hasKey ? "API key (replace)" : "API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Save") {
                    if !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        keyStore.save(key: keyDraft, for: provider)
                    }
                    persistModelDraft()
                    keyDraft = ""
                    testState = .idle
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty && modelUnchanged)
            }

            // Model choice
            HStack(spacing: 8) {
                Picker("Model", selection: $modelDraft) {
                    ForEach(modelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 260)

                TextField("Custom model id", text: $modelDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())

                Button("Test") { runTest() }
                    .disabled(testState == .running || resolvedKey.isEmpty)
            }

            // Test result line — always present so the card never jumps.
            HStack(spacing: 6) {
                switch testState {
                case .idle:
                    Text(hasKey
                         ? "Test sends a tiny non-streaming completion to verify key + model."
                         : "Paste a key, then Test.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
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
            .frame(minHeight: 16, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lfGlass()
        .onAppear {
            modelDraft = AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
                ?? provider.defaultModel
        }
    }

    /// Suggested models plus whatever is already saved (so a custom saved id
    /// always appears in the menu instead of silently vanishing).
    private var modelOptions: [String] {
        var options = provider.suggestedModels
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

    private var resolvedKey: String {
        let draft = keyDraft.trimmingCharacters(in: .whitespaces)
        if !draft.isEmpty { return draft }
        return keyStore.key(for: provider) ?? ""
    }

    private func persistModelDraft() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var preferences = AppPreferencesStore.shared.current
        preferences.remoteModel[provider.rawValue] = trimmed
        AppPreferencesStore.shared.save(preferences)
    }

    private func runTest() {
        let key = resolvedKey
        guard !key.isEmpty else {
            testState = .failed("No API key for \(provider.displayName) — paste one above first.")
            return
        }
        let model = modelDraft.trimmingCharacters(in: .whitespaces).isEmpty
            ? provider.defaultModel
            : modelDraft.trimmingCharacters(in: .whitespaces)
        testState = .running
        Task {
            do {
                let answered = try await RemoteLLMClient.testConnection(
                    provider: provider, apiKey: key, model: model)
                testState = .ok("Connected — answered as \(answered) (\(model))")
            } catch {
                testState = .failed((error as? LocalizedError)?.errorDescription
                                      ?? error.localizedDescription)
            }
        }
    }
}
