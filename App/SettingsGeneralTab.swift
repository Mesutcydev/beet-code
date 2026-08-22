import AppKit
import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var tokenStore = HFTokenStore.shared
    @State private var tokenDraft = ""
    @State private var validationMessage: String?
    @State private var isValidating = false

    var body: some View {
        TabScroll {
            SettingsCard(title: "Composer", icon: "text.cursor", footer: "The border traces the selected flow. Response style is used in the agent’s final handoff.") {
                SettingRow(label: "Style") {
                    Picker("Composer style", selection: $settings.composerFlow) {
                        ForEach(ComposerFlow.allCases) { flow in
                            Text(flow.label).tag(flow)
                        }
                    }
                    .labelsHidden()
                }
                SettingRow(label: "Response style", value: settings.outputStyle.help) {
                    Picker("Response style", selection: $settings.outputStyle) {
                        ForEach(ProjectPolicy.OutputStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                }
                SettingToggle(label: "Animated border", isOn: $settings.composerBorderAnimation)
            }

            SettingsCard(title: "Keyboard", icon: "keyboard", footer: "Shortcuts accept readable forms such as cmd+return. Esc always stops a running agent, and ⇧⌘M opens Model Manager.") {
                SettingToggle(label: "Enter sends", isOn: $settings.enterSends)
                Text(settings.enterSends
                     ? "Enter sends the message; Shift+Enter inserts a newline. The configured Send shortcut also works anywhere."
                     : "Enter inserts a newline. Use the configured Send shortcut to send.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                SettingRow(label: "Send shortcut", value: ShortcutBinding(rawValue: settings.sendShortcut).displayValue) {
                    ShortcutEditor(placeholder: "cmd+return", value: $settings.sendShortcut)
                }
                SettingRow(label: "Stop shortcut", value: ShortcutBinding(rawValue: settings.stopShortcut).displayValue) {
                    ShortcutEditor(placeholder: "cmd+.", value: $settings.stopShortcut)
                }
                SettingRow(label: "Plan shortcut", value: ShortcutBinding(rawValue: settings.planShortcut).displayValue) {
                    ShortcutEditor(placeholder: "cmd+shift+p", value: $settings.planShortcut)
                }
            }

            SettingsCard(
                title: "Appearance",
                icon: "paintbrush",
                footer: "Dark is the everyday default. Beet tints the whole window; use it as a theme, not the reading surface.") {
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

            SettingsCard(title: "Local API Server", icon: "network", footer: "Loopback-only OpenAI-compatible endpoint for the active model. Nothing outside this Mac can reach it.") {
                SettingToggle(label: "Enable local API server", isOn: $settings.apiServerEnabled)
                SettingRow(label: "Port") {
                    TextField("1234", value: $settings.apiServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .monospacedDigit()
                }
                SettingRow(label: "Bearer token") {
                    TextField("Required", text: Binding(
                        get: { settings.apiServerToken },
                        set: { settings.apiServerToken = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .frame(minWidth: 180)
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
                        let token = settings.ensureAPIServerToken()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            """
                            curl \(appState.apiServerBaseURL)/v1/chat/completions \\
                              -H 'Content-Type: application/json' \\
                              -H 'Authorization: Bearer \(token)' \\
                              -d '{"model":"beetcode","messages":[{"role":"user","content":"Hello"}]}'
                            """,
                            forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.apiServerRunning)
                }
            }

            SettingsCard(title: "Remote Beetcode Sessions", icon: "iphone", footer: "Off by default. Tailscale is preferred; the QR is a one-time pairing code.") {
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
