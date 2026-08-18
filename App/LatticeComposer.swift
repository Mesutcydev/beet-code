import SwiftUI

/// Chips-first Intent composer. Two orthogonal axes — Roles (how to act)
/// and Focus (what to look at). No 48-cell matrix: a role is on or off,
/// a focus source is on or off. One tap selects, another deselects.

// MARK: - Roles

enum IntentRole: String, CaseIterable, Identifiable, Sendable {
    case research, build, review, verify

    var id: String { rawValue }

    /// Fixed pipeline order for composition and display.
    var order: Int {
        switch self {
        case .research: 0
        case .build: 1
        case .review: 2
        case .verify: 3
        }
    }

    var label: String {
        switch self {
        case .research: "Research"
        case .build: "Build"
        case .review: "Review"
        case .verify: "Verify"
        }
    }

    var glyph: String {
        switch self {
        case .research: "magnifyingglass"
        case .build: "hammer"
        case .review: "checkmark.seal"
        case .verify: "testtube.2"
        }
    }

    var color: Color {
        switch self {
        case .research: Color.dynamic(light: 0x0E9AAB, dark: 0x45CBDA)
        case .build: Theme.info
        case .review: Theme.success
        case .verify: Theme.warning
        }
    }

    /// Exact instruction injected for this role. One sentence, ~20 tokens.
    var instruction: String {
        switch self {
        case .research:
            "Read the relevant code and project context before proposing or making changes; never guess what's in a file."
        case .build:
            "Implement the change file by file; keep each edit minimal and say what changed and why."
        case .review:
            "Check the change for correctness, edge cases, and style; report concerns by severity."
        case .verify:
            "Run the relevant builds/tests after editing; if anything fails, report the exact command and the key output."
        }
    }
}

// MARK: - Focus sources

enum FocusSource: String, CaseIterable, Identifiable, Sendable {
    case files, git, docs, codebase

    var id: String { rawValue }
    var mention: String { "@" + rawValue }
    var label: String { rawValue.capitalized }

    var glyph: String {
        switch self {
        case .files: "doc"
        case .git: "arrow.triangle.branch"
        case .docs: "book"
        case .codebase: "folder"
        }
    }

    /// Lower number survives budget pruning longer.
    var prunePriority: Int {
        switch self {
        case .files: 0
        case .git: 1
        case .docs: 2
        case .codebase: 3
        }
    }
}

// MARK: - Resolved focus

struct ResolvedFocus: Sendable, Equatable {
    var source: FocusSource
    var summary: String
    var content: String
    var found: Bool
}

enum FocusResolver {
    static let cap = 8_000

    static func resolve(
        _ source: FocusSource,
        workspace: URL?,
        attachments: [ComposerAttachment]
    ) -> ResolvedFocus {
        switch source {
        case .files:
            let names = attachments.map(\.name).filter { !$0.isEmpty }
            if names.isEmpty {
                return ResolvedFocus(source: .files, summary: "(nothing found)", content: "", found: false)
            }
            return ResolvedFocus(
                source: .files,
                summary: "attached: \(names.joined(separator: ", ")).",
                content: "",
                found: true)

        case .git:
            guard let root = workspace, isGitRepo(root) else {
                return ResolvedFocus(source: .git, summary: "(nothing found)", content: "", found: false)
            }
            let branch = gitHead(root) ?? "HEAD"
            let status = boundedShell(root, ["git", "status", "--short"], cap: 2_000)
            let diff = boundedShell(root, ["git", "diff", "--stat"], cap: 4_000)
            var body = "branch: \(branch)\n"
            if !status.isEmpty { body += status + "\n" }
            if !diff.isEmpty { body += diff }
            let clipped = String(body.prefix(Self.cap))
            return ResolvedFocus(
                source: .git,
                summary: "current branch and uncommitted diff appended below.",
                content: clipped,
                found: true)

        case .docs:
            guard let root = workspace else {
                return ResolvedFocus(source: .docs, summary: "(nothing found)", content: "", found: false)
            }
            let docsDir = root.appendingPathComponent("docs", isDirectory: true)
            let names = markdownNames(in: docsDir)
            if names.isEmpty {
                return ResolvedFocus(source: .docs, summary: "(nothing found)", content: "", found: false)
            }
            return ResolvedFocus(
                source: .docs,
                summary: "docs/: \(names.prefix(8).joined(separator: ", ")).",
                content: "",
                found: true)

        case .codebase:
            guard let root = workspace else {
                return ResolvedFocus(source: .codebase, summary: "(nothing found)", content: "", found: false)
            }
            return ResolvedFocus(
                source: .codebase,
                summary: "workspace \(root.lastPathComponent) — search the tree before guessing.",
                content: "",
                found: true)
        }
    }

    private static func isGitRepo(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
    }

    private static func gitHead(_ root: URL) -> String? {
        let head = root.appendingPathComponent(".git/HEAD")
        guard let raw = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: ") {
            return line.split(separator: "/").last.map(String.init)
        }
        return String(line.prefix(8))
    }

    private static func markdownNames(in directory: URL) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "md" }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Short, bounded `Process` — never used on the hot path except at send.
    private static func boundedShell(_ root: URL, _ args: [String], cap: Int) -> String {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.prefix(cap)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Model

@MainActor
final class LatticeModel: ObservableObject {
    @Published var isExpanded = false
    @Published private(set) var roles: Set<IntentRole> = []
    @Published private(set) var focuses: Set<FocusSource> = []

    func toggle(_ role: IntentRole) {
        if roles.contains(role) { roles.remove(role) } else { roles.insert(role) }
    }

    func toggle(_ focus: FocusSource) {
        if focuses.contains(focus) { focuses.remove(focus) } else { focuses.insert(focus) }
    }

    func clear() {
        roles.removeAll()
        focuses.removeAll()
    }

    var activeRoleCount: Int { roles.count }
    var activeFocusCount: Int { focuses.count }
    var selectionCount: Int { roles.count + focuses.count }
    var isEmpty: Bool { roles.isEmpty && focuses.isEmpty }

    var orderedRoles: [IntentRole] {
        IntentRole.allCases.filter { roles.contains($0) }
    }

    var orderedFocuses: [FocusSource] {
        FocusSource.allCases.filter { focuses.contains($0) }
    }

    struct Preset: Identifiable, Sendable {
        let id: String
        let name: String
        let glyph: String
        let roles: [IntentRole]
    }

    static let presets: [Preset] = [
        Preset(id: "research", name: "Research first", glyph: "magnifyingglass", roles: [.research]),
        Preset(id: "ship", name: "Ship it", glyph: "shippingbox", roles: [.build, .verify]),
        Preset(id: "verify", name: "Test & verify", glyph: "checkmark.seal", roles: [.verify, .review]),
        Preset(id: "pipeline", name: "Full pipeline", glyph: "arrow.triangle.merge",
               roles: [.research, .build, .review, .verify]),
    ]

    func apply(_ preset: Preset) {
        roles = Set(preset.roles)
    }

    /// Honest intent block prepended to the user message. Empty selection
    /// returns nil so the draft is sent untouched.
    func contextPreamble(
        workspace: URL? = nil,
        attachments: [ComposerAttachment] = [],
        draft: String = "",
        contextWindow: Int? = nil
    ) -> String? {
        let composed = compose(
            workspace: workspace, attachments: attachments, draft: draft, contextWindow: contextWindow)
        return composed.text
    }

    struct Composition: Sendable {
        var text: String?
        var estimatedTokens: Int
        var budget: Int?
        var prunedFocuses: [FocusSource]
    }

    func compose(
        workspace: URL? = nil,
        attachments: [ComposerAttachment] = [],
        draft: String = "",
        contextWindow: Int? = nil
    ) -> Composition {
        guard !isEmpty else {
            let draftTokens = LatticeEngine.estimateTokens(draft)
            return Composition(text: nil, estimatedTokens: draftTokens, budget: contextWindow, prunedFocuses: [])
        }

        var lines: [String] = ["Intent for this turn:"]
        for role in orderedRoles {
            lines.append("- \(role.label): \(role.instruction)")
        }

        var resolved = orderedFocuses.map {
            FocusResolver.resolve($0, workspace: workspace, attachments: attachments)
        }

        // Role instructions are never pruned. Drop lowest-priority focus
        // content first when a real window is known and we would overflow.
        var pruned: [FocusSource] = []
        if let window = contextWindow, window > 0 {
            let reserve = 4_000
            let roleText = lines.joined(separator: "\n")
            var used = LatticeEngine.estimateTokens(roleText + "\n" + draft)
            let ranked = resolved.enumerated().sorted { a, b in
                a.element.source.prunePriority > b.element.source.prunePriority
            }
            for item in ranked {
                let extra = LatticeEngine.estimateTokens(item.element.content)
                if used + extra > max(1, window - reserve), !item.element.content.isEmpty {
                    resolved[item.offset].content = ""
                    resolved[item.offset].summary += " (content dropped to fit the context budget)"
                    pruned.append(item.element.source)
                } else {
                    used += extra
                }
            }
        }

        if !resolved.isEmpty {
            lines.append("")
            lines.append("Focus:")
            for item in resolved {
                if item.found {
                    lines.append("- \(item.source.mention) — \(item.summary)")
                } else {
                    lines.append("- \(item.source.mention) — (nothing found).")
                }
            }
            for item in resolved where !item.content.isEmpty {
                lines.append("")
                lines.append(item.content)
            }
        }

        let text = lines.joined(separator: "\n")
        let tokens = LatticeEngine.estimateTokens(text + "\n" + draft)
        return Composition(text: text, estimatedTokens: tokens, budget: contextWindow, prunedFocuses: pruned)
    }

    func estimatedTokens(draft: String = "") -> Int {
        compose(draft: draft).estimatedTokens
    }
}

// MARK: - Palette (chips-first)

struct IntentPalette: View {
    @ObservedObject var model: LatticeModel
    var estimatedTokens: Int = 0
    var contextWindow: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Intent", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Roles say how to act. Focus says what to look at.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.isExpanded = false }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Collapse the intent palette")
            }

            presetsRow
            chipRow(title: "Roles", items: IntentRole.allCases.map { role in
                PaletteChip(
                    id: role.id,
                    label: role.label,
                    glyph: role.glyph,
                    color: role.color,
                    selected: model.roles.contains(role),
                    action: { withAnimation(.easeOut(duration: 0.12)) { model.toggle(role) } })
            })
            chipRow(title: "Focus", items: FocusSource.allCases.map { focus in
                PaletteChip(
                    id: focus.id,
                    label: focus.mention,
                    glyph: focus.glyph,
                    color: Theme.accent,
                    selected: model.focuses.contains(focus),
                    action: { withAnimation(.easeOut(duration: 0.12)) { model.toggle(focus) } })
            })

            if !model.isEmpty {
                selectedStrip
            }

            if estimatedTokens > 0, shouldShowMeter {
                IntentTelemetryLine(tokens: estimatedTokens, window: contextWindow)
            }
        }
    }

    private var shouldShowMeter: Bool {
        guard let window = contextWindow, window > 0 else { return estimatedTokens > 400 }
        return Double(estimatedTokens) / Double(window) > 0.05 || estimatedTokens > 400
    }

    private var presetsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Suggested")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                ForEach(LatticeModel.presets) { preset in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { model.apply(preset) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: preset.glyph)
                                .font(.system(size: 10, weight: .semibold))
                            Text(preset.name)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.accentSoft, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.30), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Select \(preset.roles.map(\.label).joined(separator: ", "))")
                }
            }
        }
    }

    private func chipRow(title: String, items: [PaletteChip]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 8) {
                ForEach(items) { chip in chip }
                Spacer(minLength: 0)
            }
        }
    }

    private var selectedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.orderedRoles) { role in
                    removableChip(text: role.label, color: role.color) { model.toggle(role) }
                }
                ForEach(model.orderedFocuses) { focus in
                    removableChip(text: focus.mention, color: Theme.accent) { model.toggle(focus) }
                }
                Button("Clear") { model.clear() }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func removableChip(text: String, color: Color, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .medium))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}

private struct PaletteChip: View, Identifiable {
    let id: String
    let label: String
    let glyph: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(selected ? color : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                selected ? color.opacity(0.16) : Theme.surfaceInset,
                in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? color.opacity(0.55) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(selected ? "Remove \(label)" : "Add \(label)")
    }
}

struct IntentTelemetryLine: View {
    let tokens: Int
    let window: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text("≈ \(tokens) tok")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
            if let window, window > 0 {
                let pct = min(1, Double(tokens) / Double(window))
                let color: Color = pct > 0.8 ? Theme.danger : pct > 0.5 ? Theme.warning : Theme.success
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceInset)
                        Capsule().fill(color).frame(width: g.size.width * pct)
                    }
                }
                .frame(width: 80, height: 5)
                Text("\(Int(pct * 100))% of \(window / 1024)K")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            Spacer()
        }
    }
}

// MARK: - Accessory hit targets

private struct AccessoryControlModifier: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .controlSize(.regular)
            .frame(minHeight: 28)
            .brightness(hovering ? 0.03 : 0)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func accessoryControl() -> some View {
        modifier(AccessoryControlModifier())
    }
}
