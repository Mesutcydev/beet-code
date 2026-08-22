import AppKit
import SwiftUI

// MARK: - Plugins tab

/// Universal compatibility surface for declarative skills and workflows.
/// Files stay at their source and executable plugin setup is never run.
struct PluginsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var commands: [ExternalCommand] = []
    @State private var instructionSource: String?
    @State private var externalRoots: [String] = []
    @State private var showsCommands = false
    @State private var isScanning = false

    var body: some View {
        TabScroll {
            InfoBanner(
                icon: "puzzlepiece.extension",
                text: "Bring your coding setup with you. Beet Code finds compatible skills, commands, prompts and workflows, then makes them available as slash commands in the composer.")

            SettingsCard(
                title: "Import from coding tools",
                icon: "square.and.arrow.down",
                footer: "Claude Code, Codex, Cursor, Copilot, Windsurf, OpenCode and Agent Skills are detected automatically. Plugin scripts and installers are never executed.") {
                HStack(spacing: Spacing.sm) {
                    Button(action: addIDEFolder) {
                        Label("Add IDE folder", systemImage: "plus")
                    }
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                    .help("Choose a skill, plugin, commands, prompts or workflows folder")

                    Button(action: reload) {
                        Label(isScanning ? "Scanning" : "Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                    .disabled(isScanning)
                    .help("Scan connected coding tools again")

                    Spacer()

                    Text(isScanning ? "Looking for capabilities…" : commands.isEmpty ? "Nothing found" : "\(commands.count) ready")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(commands.isEmpty ? Theme.textTertiary : Theme.success)
                }

                Divider().overlay(Theme.hairline)

                ForEach(sourceSummaries, id: \.origin) { summary in
                    SettingRow(label: summary.origin.rawValue, value: summary.detail) {
                        Text("\(summary.count)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(summary.count == 0 ? Theme.textTertiary : Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.surfaceInset, in: Capsule())
                    }
                }
            }

            SettingsCard(
                title: "Connected folders",
                icon: "folder.badge.plus",
                footer: "Add a folder from any IDE or plugin pack. Beet Code reads SKILL.md files and Markdown commands, prompts and workflows in place, so updates remain in sync.") {
                if externalRoots.isEmpty {
                    Text("No extra folders connected.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(externalRoots, id: \.self) { path in
                        SettingRow(
                            label: URL(fileURLWithPath: path).lastPathComponent,
                            value: path) {
                            Button {
                                removeExternalRoot(path)
                            } label: {
                                Image(systemName: "minus")
                            }
                            .buttonStyle(LFIconButtonStyle(size: 26))
                            .help("Disconnect this folder")
                            .accessibilityLabel("Disconnect \(URL(fileURLWithPath: path).lastPathComponent)")
                        }
                    }
                }
            }

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
                title: "Available in the composer",
                icon: "slash.circle",
                footer: "Type /help in the composer to see the same list while you work. Workspace capabilities take precedence when two commands use the same name.") {
                if commands.isEmpty {
                    Text("No external commands discovered yet.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    DisclosureGroup(isExpanded: $showsCommands) {
                        VStack(alignment: .leading, spacing: Spacing.md) {
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
                        .padding(.top, Spacing.sm)
                    } label: {
                        Text("Show \(commands.count) slash commands")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .tint(Theme.accent)
                }
            }
            if !appState.openCodeCatalog.agents.isEmpty || !appState.openCodeCatalog.mcpServers.isEmpty {
                SettingsCard(
                    title: "OpenCode compatibility",
                    icon: "arrow.triangle.branch",
                    footer: "Build and Plan are native Beet Code profiles. Imported agents and MCP servers keep their source configuration and are applied through Beet Code's approval flow.") {
                    if !appState.openCodeCatalog.agents.isEmpty {
                        SettingRow(label: "Agents", value: appState.openCodeCatalog.agents.map(\.name).joined(separator: " · ")) {
                            Image(systemName: "person.2.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    if !appState.openCodeCatalog.mcpServers.isEmpty {
                        SettingRow(label: "MCP servers", value: appState.openCodeCatalog.mcpServers.keys.sorted().joined(separator: " · ")) {
                            Image(systemName: "network")
                                .foregroundStyle(Theme.info)
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private struct SourceSummary {
        let origin: ExternalCommand.Origin
        let count: Int
        let detail: String
    }

    private var sourceSummaries: [SourceSummary] {
        let alwaysVisible: [ExternalCommand.Origin] = [
            .claude, .codex, .cursor, .copilot, .windsurf, .openCode
        ]
        let optional: [ExternalCommand.Origin] = [.agent, .external, .beetcode]
        return (alwaysVisible + optional).compactMap { origin in
            let items = commands.filter { $0.origin == origin }
            guard alwaysVisible.contains(origin) || !items.isEmpty else { return nil }
            let kinds = Set(items.map(\.kind.label)).sorted().joined(separator: " · ")
            return SourceSummary(
                origin: origin,
                count: items.count,
                detail: kinds.isEmpty ? "No compatible resources found" : kinds)
        }
    }

    /// Commands grouped by origin in a stable order so the expanded list
    /// never reshuffles between scans.
    private var grouped: [(String, [ExternalCommand])] {
        let order: [ExternalCommand.Origin] = [
            .claude, .codex, .cursor, .copilot, .windsurf,
            .agent, .openCode, .external, .beetcode
        ]
        return order.compactMap { origin in
            let items = commands.filter { $0.origin == origin }
            return items.isEmpty ? nil : (origin.rawValue, items)
        }
    }

    private func reload() {
        externalRoots = AppPreferencesStore.shared.current.externalResourcePaths
        let workspace = appState.sessions.workspaceURL
        instructionSource = workspace.flatMap { ProjectInstructions.load(workspaceRoot: $0)?.source }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let additionalRoots = externalRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        isScanning = true
        Task {
            let discovered = await Task.detached(priority: .utility) {
                ExternalCommands.discover(
                    home: home,
                    workspace: workspace,
                    additionalRoots: additionalRoots)
            }.value
            commands = discovered
            isScanning = false
        }
    }

    private func addIDEFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Skills or Plugin Folder"
        panel.message = "Choose a folder containing skills, commands, prompts, workflows, or an IDE plugin pack."
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.standardizedFileURL.path
        var preferences = AppPreferencesStore.shared.current
        if !preferences.externalResourcePaths.contains(path) {
            preferences.externalResourcePaths.append(path)
            AppPreferencesStore.shared.save(preferences)
        }
        reload()
    }

    private func removeExternalRoot(_ path: String) {
        var preferences = AppPreferencesStore.shared.current
        preferences.externalResourcePaths.removeAll { $0 == path }
        AppPreferencesStore.shared.save(preferences)
        reload()
    }
}
