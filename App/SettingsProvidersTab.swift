import AppKit
import SwiftUI

// MARK: - Providers tab

struct ProvidersTab: View {
    @EnvironmentObject private var appState: AppState
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
            CodexAccountCard()
            ForEach(LLMProvider.allCases) { provider in
                ProviderCard(provider: provider)
            }
            SettingsCard(
                title: "Compatible provider presets",
                icon: "network",
                footer: "These gateways use the OpenAI-compatible protocol. Save a key, refresh models, then choose an exact provider/model pair from the composer. The key is stored in the macOS Keychain.") {
                ForEach(KnownRemoteProvider.all) { provider in
                    KnownProviderRow(provider: provider)
                }
            }
            if !appState.openCodeCatalog.providers.isEmpty {
                SettingsCard(
                    title: "Imported OpenCode providers",
                    icon: "arrow.down.circle",
                    footer: "Imported from opencode.json / opencode.jsonc. Keys referenced by environment or file are used in memory only; keys entered here are stored in the macOS Keychain.") {
                    ForEach(appState.openCodeCatalog.providers) { provider in
                        OpenCodeProviderRow(provider: provider)
                    }
                }
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

/// Account-backed OpenAI access is deliberately a separate card from BYOK:
/// ChatGPT sign-in is handled by Codex app-server, while API keys remain
/// independent Keychain credentials with usage-based billing.
struct CodexAccountCard: View {
    @ObservedObject private var codex = CodexAccountStore.shared
    @State private var copiedCode = false

    var body: some View {
        SettingsCard(
            title: "OpenAI account",
            icon: "person.crop.circle",
            footer: "Sign in with ChatGPT to use the models available to your account. Beet Code never asks for or stores the ChatGPT refresh token; the installed Codex app-server owns browser login, refresh, logout, tools, MCP, and approvals.") {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(codex.isSignedIn ? "Connected to ChatGPT" : "Use OpenAI with your account")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.md)
                statusBadge
            }

            if !codex.isSignedIn {
                HStack(spacing: Spacing.sm) {
                    Button("Sign in with ChatGPT…") {
                        Task { await codex.signInWithBrowser() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)

                    Button("Use device code") {
                        Task { await codex.signInWithDeviceCode() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    Button("Refresh models") {
                        Task { await codex.refreshModels() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Sign out") {
                        Task { await codex.signOut() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.danger)
                    .controlSize(.small)
                }
            }

            if let deviceCode = codex.deviceCodeLogin {
                deviceCodeRow(deviceCode)
            } else if codex.browserLogin != nil {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Finish sign-in in your browser, then return to Beet Code.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Cancel") { Task { await codex.cancelLogin() } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let error = codex.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await codex.refresh() }
    }

    private var accountSubtitle: String {
        if !codex.isAvailable { return "Codex CLI was not found. Install it to enable account login." }
        if let account = codex.account {
            return "\(account.displayPlan) · \(codex.models.count) models available in the composer"
        }
        return "Browser login or device code login opens the official Codex authentication flow."
    }

    private var statusBadge: some View {
        Label(
            codex.isSignedIn ? "Connected" : (codex.isAvailable ? "Not connected" : "Unavailable"),
            systemImage: codex.isSignedIn ? "checkmark.circle.fill" : "circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(codex.isSignedIn ? Theme.success : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.wash(codex.isSignedIn ? Theme.success : Theme.textSecondary), in: Capsule())
    }

    private func deviceCodeRow(_ login: CodexDeviceCodeLogin) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Enter this code in the browser")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(login.userCode)
                    .font(.title3.weight(.semibold).monospaced())
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            Button(copiedCode ? "Copied" : "Copy code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(login.userCode, forType: .string)
                copiedCode = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Open") { NSWorkspace.shared.open(login.verificationURL) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Cancel") { Task { await codex.cancelLogin() } }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Spacing.sm)
        .lfWashCard(Theme.accent)
    }
}
