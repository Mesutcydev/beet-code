import Foundation

// MARK: - Intent model
//
// A message carries an optional *Intent*: a deduplicated, ordered set of
// Roles (behavior directives for this turn) plus an optional *Focus* (context
// sources that resolve to real, bounded content — or are honestly reported
// as empty). This is the successor of the role × context lattice: two
// orthogonal chip rows instead of a 48-cell matrix.
//
// Design contract (docs/LATTICE-REDESIGN-SPEC.md):
// - Binary selection only. No weights, no muted state, no priorities.
// - Roles render in a fixed pipeline order regardless of tap order.
// - Focus lines state what was actually included; empty resolvers are marked
//   "(nothing found)" and never fabricate content.
// - No invented fences and no numeric metadata — one labeled markdown block
//   the model can actually act on.

/// What the agent should do this turn. Fixed pipeline order:
/// research → build → review → verify.
public enum IntentRole: String, CaseIterable, Codable, Sendable, Identifiable {
    case research, build, review, verify

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .research: "Research"
        case .build: "Build"
        case .review: "Review"
        case .verify: "Verify"
        }
    }

    public var glyph: String {
        switch self {
        case .research: "doc.text.magnifyingglass"
        case .build: "hammer"
        case .review: "eye"
        case .verify: "checkmark.seal"
        }
    }

    /// The exact instruction line injected into the message (after "- ").
    /// Single instruction per role — short enough to never be a budget
    /// concern, concrete enough for small local models to follow.
    public var instruction: String {
        switch self {
        case .research:
            "Research: Read the relevant code and project context before proposing or making changes; never guess what's in a file."
        case .build:
            "Build: Implement the change file by file; keep each edit minimal and say what changed and why."
        case .review:
            "Review: Check the change for correctness, edge cases, and style; report concerns by severity."
        case .verify:
            "Verify: Run the relevant builds/tests after editing; if anything fails, report the exact command and the key output."
        }
    }
}

/// Extra context sources attached to a turn. Every source has a resolver in
/// the app layer that produces bounded content or an empty string.
public enum FocusSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case files, git, docs, codebase

    public var id: String { rawValue }

    /// Display label, including the @ prefix used in the Focus section.
    public var label: String {
        switch self {
        case .files: "@files"
        case .git: "@git"
        case .docs: "@docs"
        case .codebase: "@codebase"
        }
    }

    public var glyph: String {
        switch self {
        case .files: "doc"
        case .git: "arrow.triangle.branch"
        case .docs: "book"
        case .codebase: "square.grid.2x2"
        }
    }

    /// What the user is granting, shown in tooltips.
    public var summary: String {
        switch self {
        case .files: "Quoted contents of the files attached to this message."
        case .git: "Current branch, uncommitted status, and diff stat."
        case .docs: "The project's documentation index (README, docs/*.md)."
        case .codebase: "A bounded map of the workspace's top-level structure."
        }
    }

    /// The Focus-section line used when the resolver produced content.
    public var includedDescription: String {
        switch self {
        case .files: "attached files are quoted with this message"
        case .git: "current branch and uncommitted diff appended below"
        case .docs: "project documentation index appended below"
        case .codebase: "workspace map appended below"
        }
    }

    /// Whether resolved content is appended as a block after the preamble.
    /// @files is the exception: attachment contents already travel with the
    /// message through the composer pipeline, so only the names are listed.
    public var appendsResolvedBlock: Bool {
        self != .files
    }
}

/// Whether a focus source can be selected right now, with an honest reason
/// when it can't (rendered as a tooltip on the disabled chip).
public enum FocusAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// The user's intent for one turn: binary selection, deduplicated by
/// construction (sets), ordered by the fixed pipeline/focus order at
/// composition time — never by tap order.
public struct IntentSelection: Codable, Sendable, Equatable {
    public var roles: Set<IntentRole> = []
    public var focus: Set<FocusSource> = []

    public init() {}

    public var isEmpty: Bool { roles.isEmpty && focus.isEmpty }
    public var count: Int { roles.count + focus.count }

    public var orderedRoles: [IntentRole] { IntentRole.allCases.filter(roles.contains) }
    public var orderedFocus: [FocusSource] { FocusSource.allCases.filter(focus.contains) }
}

// MARK: - Presets

/// A named role curation. Presets replace the role selection; they never
/// touch focus sources (those depend on the workspace, not the workflow).
public struct IntentPreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let glyph: String
    public let summary: String
    public let roles: [IntentRole]
}

public enum IntentPresets {
    public static let all: [IntentPreset] = [
        IntentPreset(
            id: "research-first", name: "Research first", glyph: "doc.text.magnifyingglass",
            summary: "Gather context, then answer — change nothing.",
            roles: [.research]),
        IntentPreset(
            id: "ship-it", name: "Ship it", glyph: "hammer",
            summary: "Implement, then prove it builds and tests pass.",
            roles: [.build, .verify]),
        IntentPreset(
            id: "test-verify", name: "Test & verify", glyph: "checkmark.seal",
            summary: "Run the suite and critique the result.",
            roles: [.verify, .review]),
        IntentPreset(
            id: "full-pipeline", name: "Full pipeline", glyph: "list.bullet.indent",
            summary: "Research, build, review, verify — in order.",
            roles: [.research, .build, .review, .verify]),
    ]

    public static func preset(id: String) -> IntentPreset? {
        all.first { $0.id == id }
    }
}

// MARK: - Token estimation

/// One honest estimator: tokens ≈ chars/4, always labeled with ≈ in the UI.
/// No fudge terms; where a real tokenizer is available the caller should use
/// that instead and drop the ≈.
public enum IntentTokens {
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.count + 3) / 4)
    }
}

// MARK: - Composition

/// Serializes a selection into the user-authored intent block prepended to
/// the outgoing message. The template is a plain labeled markdown section:
///
///     Intent for this turn:
///     - Research: Read the relevant code …
///     - Build: Implement the change …
///
///     Focus:
///     - @git — current branch and uncommitted diff appended below.
///     - @docs — (nothing found).
///
///     <resolved @git content, bounded>
///
///     <the user's draft>
///
/// Rules: roles deduplicated and in fixed order; no weights or tiers; focus
/// lines state what was actually included; resolved content appended after
/// the preamble in fixed focus order; an empty selection returns the draft
/// untouched.
public enum IntentComposer {

    public static func compose(
        selection: IntentSelection,
        draft: String,
        resolve: (FocusSource) -> String
    ) -> String {
        guard !selection.isEmpty else { return draft }

        var blocks: [String] = []

        if !selection.roles.isEmpty {
            let lines = selection.orderedRoles.map { "- \($0.instruction)" }
            blocks.append((["Intent for this turn:"] + lines).joined(separator: "\n"))
        }

        var resolvedBlocks: [String] = []
        if !selection.focus.isEmpty {
            var focusLines: [String] = []
            for source in selection.orderedFocus {
                let content = resolve(source).trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty {
                    focusLines.append("- \(source.label) — (nothing found).")
                } else if source.appendsResolvedBlock {
                    focusLines.append("- \(source.label) — \(source.includedDescription).")
                    resolvedBlocks.append(content)
                } else {
                    // @files: names ride in the line, contents via attachments.
                    focusLines.append("- \(source.label) — \(source.includedDescription): \(content).")
                }
            }
            blocks.append((["Focus:"] + focusLines).joined(separator: "\n"))
        }

        blocks.append(contentsOf: resolvedBlocks)
        blocks.append(draft)
        return blocks.joined(separator: "\n\n")
    }
}
