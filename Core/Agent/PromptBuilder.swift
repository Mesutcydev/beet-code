import Foundation

/// Builds the system prompt that teaches the model the tool protocol. Works
/// with any model regardless of native function-calling support — the model
/// emits fenced ```tool JSON blocks that ToolParser extracts.
enum PromptBuilder {

    static func systemPrompt(
        tools: [any AgentTool],
        workspace: Workspace,
        repoIndex: RepoIndex? = nil,
        memorySection: String? = nil,
        projectInstructions: String? = nil,
        workspaceHistory: String? = nil,
        planMode: Bool = false,
        goalMode: Bool = false,
        contextWindowTokens: Int? = nil,
        responseReserveTokens: Int = 4096
    ) -> String {
        var sections: [String] = []
        sections.append("""
        You are Beet Code, an autonomous coding agent working inside the user's \
        project directory: \(workspace.root.path)

        You accomplish tasks by using tools, one per message. Think briefly, then \
        act. Prefer reading before writing. Verify your work by running commands \
        when useful. Be concise in prose — spend your effort on correct tool calls.
        """)

        if planMode {
            sections.append("""
            # Plan mode

            You are in PLAN mode. Your FIRST reply must be a concise plan of
            what you will do — reading, edits, and commands you intend to run.
            Do NOT call any tool yet. Wait for the user to approve the plan.
            Once approved, execute the plan step by step with tools.
            """)
        }

        if goalMode {
            sections.append("""
            # Goal mode

            Stay focused on the user's complete goal. After the plan is
            approved, keep inspecting, editing, verifying, and correcting until
            the requested outcome is actually complete. Do not stop after a
            partial change; use attempt_completion only when the goal is done
            or a concrete blocker needs the user's input.
            """)
        }

        sections.append("""
        # Tool protocol

        To call a tool, emit exactly one fenced block:

        ```tool
        {"name": "<tool>", "arguments": { … }}
        ```

        Rules:
        - One tool call per reply. After each call you receive its output as the \
        next message, then continue.
        - Use only the listed tools with valid JSON arguments.
        - When the task is fully complete, call `attempt_completion` with a short \
        summary of what changed.
        - If you need information only the user can provide, call `ask_user`.
        """)

        var toolDocs: [String] = []
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            toolDocs.append("## \(tool.name) — \(tool.summary)\n\(tool.schemaText)")
        }
        sections.append("# Available tools\n\n" + toolDocs.joined(separator: "\n\n"))

        // Capability guidance: the tool list alone doesn't teach the model
        // WHEN to reach for the in-app browser or the simulator. Derived from
        // the actual tool list so it never advertises something absent.
        if let guidance = capabilityGuidance(tools: tools) {
            sections.append(guidance)
        }

        // Bounded repository context: the model sees the project shape and
        // per-file summaries instead of raw file dumps. Summaries survive
        // compaction because they live in the system prompt.
        if let repoIndex, !repoIndex.entries.isEmpty {
            sections.append(
                "# Workspace structure (bounded index)\n\n\(bounded(repoIndex.render, characters: 8_000))")
        }

        // Long-term memory: durable facts and earlier-session summaries. Like
        // the repo index, memory lives in the system prompt so compaction
        // never evicts it.
        if let memorySection {
            sections.append("# Memory\n\n\(bounded(memorySection, characters: 6_000))")
        }

        // Project conventions (AGENTS.md / CLAUDE.md): the project's own
        // instructions for agents — build commands, style rules, forbidden
        // paths. Loaded verbatim, bounded; lives in the prompt so compaction
        // never evicts it.
        if let projectInstructions, !projectInstructions.isEmpty {
            sections.append("# Project instructions (AGENTS.md / CLAUDE.md)\n\n\(bounded(projectInstructions, characters: 8_000))")
        }

        // Workspace history: what earlier sessions in THIS folder were about
        // — BeetCode's own and chats imported from Claude / Codex / Cursor.
        // Bounded digest; like memory it survives compaction in the prompt.
        if let workspaceHistory, !workspaceHistory.isEmpty {
            sections.append("# Earlier work in this workspace\n\n\(bounded(workspaceHistory, characters: 4_000))")
        }

        sections.append("""
        # Conventions for editing files

        Prefer `apply_patch` with SEARCH/REPLACE blocks for edits. SEARCH text \
        must match the file exactly, character-for-character, including \
        indentation. Include just enough surrounding lines to make the match \
        unique. Use `write_file` only for new files or complete rewrites. You \
        must read a file before editing it.
        """)

        let prompt = sections.joined(separator: "\n\n")
        guard let contextWindowTokens else { return prompt }

        // A model's context contains both this system prompt and the next
        // reply. Keep a response reserve so a large repository index cannot
        // make the first request fail before a tool or plan is produced.
        let promptBudget = max(
            8_000,
            (contextWindowTokens - max(1_024, responseReserveTokens) - 512) * 3)
        return fitPrompt(sections, maxCharacters: promptBudget)
    }

    /// Keeps supplementary context useful without allowing one generated
    /// section (especially a repository index) to crowd out the protocol.
    private static func bounded(_ text: String, characters: Int) -> String {
        guard text.count > characters else { return text }
        return String(text.prefix(characters))
            + "\n…[section shortened to preserve the model context budget]"
    }

    /// Trims only at section boundaries whenever possible. The required
    /// system/tool sections are built first, while later workspace details
    /// are the first content sacrificed under a small local context window.
    private static func fitPrompt(_ sections: [String], maxCharacters: Int) -> String {
        var kept: [String] = []
        var used = 0
        for section in sections {
            let separator = kept.isEmpty ? 0 : 2
            let remaining = maxCharacters - used - separator
            guard remaining > 0 else { break }
            if section.count <= remaining {
                kept.append(section)
                used += separator + section.count
            } else {
                let marker = "\n…[remaining workspace context omitted to preserve the reply budget]"
                let prefixLength = max(0, remaining - marker.count)
                if prefixLength > 0 {
                    kept.append(String(section.prefix(prefixLength)) + marker)
                }
                break
            }
        }
        return kept.joined(separator: "\n\n")
    }

    /// Teaches the model when to use the in-app browser and the built-in
    /// simulator. Sections are included only when the matching tools are
    /// actually registered, so the prompt never advertises a capability the
    /// current session doesn't have.
    static func capabilityGuidance(tools: [any AgentTool]) -> String? {
        let names = Set(tools.map(\.name))
        var blocks: [String] = []

        if names.contains("browser_navigate") {
            blocks.append("""
            ## In-app browser (browser_*)

            The app embeds a real browser you control with the `browser_*` tools. \
            Use it whenever the task involves a web page or web app:
            - `browser_navigate` to open a URL (including a local dev server you \
            started with `run_command`, e.g. http://localhost:3000).
            - `browser_read` for the page's visible text/links, `browser_click` and \
            `browser_type` to interact, `browser_eval` for anything the other tools \
            can't express.
            - `browser_screenshot` saves a PNG of the page into the workspace; pass \
            it to `describe_image` to SEE the rendered result.
            After building or changing web UI, verify it: serve it, navigate, \
            screenshot, inspect — don't claim it works from code alone.
            """)
        }

        if names.contains("sim_build_run") || names.contains("sim_list_devices") {
            blocks.append("""
            ## Built-in iOS simulator (sim_*)

            The app embeds an iOS simulator surface you control with the `sim_*` \
            tools. For iOS/tvOS work, verify on a real simulator instead of only \
            compiling:
            - `sim_build_run` is the one-shot loop: build → install → launch → \
            screenshot → describe. Prefer it for end-to-end verification.
            - For finer control: `sim_list_devices` → `sim_boot_device` → \
            `sim_launch_app`, then `sim_tap` / `sim_swipe` / `sim_type` to drive \
            the UI and `sim_describe` (accessibility tree) or `sim_screenshot` \
            (then `describe_image`) to observe it.
            Typical verify loop: change UI code → `sim_build_run` → read the \
            screenshot description → fix → repeat.
            """)
        }

        if names.contains("computer_ui_tree") {
            blocks.append("""
            ## Computer control (computer_*)

            You can observe and drive ANY Mac app with the `computer_*` tools \
            (Claude-style computer use). The discipline is ALWAYS \
            observe → act → re-observe; never act blind:
            - `computer_status` first: it reports whether Accessibility and \
            Screen Recording permissions are granted and which app is focused. \
            If a permission is missing, tell the user to grant it in \
            Settings → Agent → Computer control instead of retrying.
            - `computer_ui_tree` is your PRIMARY observation: the focused \
            app's accessibility tree as text, with each element's label and \
            screen coordinates (top-left origin). Prefer it — it is exact, \
            cheap, and needs no vision model.
            - `computer_screenshot` saves a PNG into the workspace; pass it to \
            `describe_image` when you need pixels (layout, colors, images).
            - Act with `computer_click` (coordinates straight from the ui_tree \
            line), `computer_type` (types into whatever has focus — click the \
            field first), `computer_key` (shortcuts like cmd+s), and \
            `computer_scroll`. Logout, lock screen, force-quit, and cmd+q \
            are blocked and will error if you try them.
            - After EVERY action, re-run `computer_ui_tree` to confirm the \
            result before the next step. Coordinates go stale after scrolling \
            or window moves.
            """)
        }

        if names.contains("web_fetch") {
            blocks.append("""
            ## Web fetch (web_fetch)

            `web_fetch` retrieves a public http(s) URL and returns visible text \
            (HTML stripped, bounded). Use it to read documentation or a raw \
            API response without opening the in-app browser. It needs approval. \
            Prefer `browser_*` when you must click or see layout.
            """)
        }

        if names.contains("task") {
            blocks.append("""
            ## Subagents (task)

            `task` runs a nested agent (read/write/patch/search/glob/shell, 8 turns) \
            that shares this session's approval gate. Use it to isolate a focused \
            subtask. Do not nest task calls; the child cannot spawn further \
            subagents. Child writes and commands still ask unless auto-approve \
            is on.
            """)
        }

        if names.contains("create_macos_app") || names.contains("build_diagnostics") {
            blocks.append("""
            ## Building a native Mac / iOS app

            When the user asks you to create or ship an app, do not invent an \
            Xcode project by hand:
            - Empty folder / new Mac app: call `create_macos_app` first \
            (XcodeGen `project.yml` + SwiftUI skeleton). Then edit files.
            - After adding or removing Swift files: `run_command` \
            `xcodegen generate` if `project.yml` exists.
            - Verify with `build_diagnostics` (no command argument). It picks \
            `xcodebuild -destination 'platform=macOS'` for .xcodeproj / \
            project.yml trees and `swift build` for SPM. Do not default to \
            `swift build` on an Xcode app — it will fail.
            - iOS UI: prefer `sim_build_run` after the Mac compile is green.
            - Stay in the workspace. Prefer `apply_patch` for edits. Read \
            before write. Fix compiler errors from `build_diagnostics` \
            before claiming done.
            """)
        }

        guard !blocks.isEmpty else { return nil }
        return "# Built-in browser, simulator & computer control\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Extracts the concatenated reasoning blocks from raw generation. Local
    /// chat templates and remote providers use several equivalent markers;
    /// normalizing them here keeps the UI and the agent loop on one contract.
    static func extractingThinking(_ text: String) -> String? {
        let blocks = thinkingBlocks(in: text, includeUnterminated: false)
        guard !blocks.isEmpty else { return nil }
        return blocks.joined(separator: "\n\n")
    }

    /// Streaming counterpart of `extractingThinking`: it also returns the
    /// currently open block so the live reasoning surface can update before a
    /// provider closes its thought section.
    static func extractingThinkingIncludingOpen(_ text: String) -> String {
        thinkingBlocks(in: text, includeUnterminated: true).joined(separator: "\n\n")
    }

    /// True when generation is currently inside a reasoning delimiter. A
    /// complete block is not considered open, so an answer can stream without
    /// leaving the “working” state permanently lit.
    static func hasOpenThinkingBlock(_ text: String) -> Bool {
        for pair in reasoningTagPairs {
            var cursor = text.startIndex
            while let open = text.range(
                of: pair.open,
                options: [.caseInsensitive],
                range: cursor..<text.endIndex)
            {
                let search = open.upperBound..<text.endIndex
                guard let close = text.range(
                    of: pair.close,
                    options: [.caseInsensitive],
                    range: search)
                else { return true }
                cursor = close.upperBound
            }
        }
        if hasOpenChannelThinkingBlock(text) { return true }
        let markerCount = text.components(separatedBy: "思考").count - 1
        return markerCount % 2 == 1
    }

    /// Strips reasoning blocks before the text is parsed for tool calls or
    /// shown as a final answer. This also removes an unterminated block when a
    /// model hits its output ceiling halfway through its private channel.
    static func strippingThinking(_ text: String) -> String {
        var result = text
        result = strippingChannelThinking(result)
        for pair in reasoningTagPairs {
            let open = NSRegularExpression.escapedPattern(for: pair.open)
            let close = NSRegularExpression.escapedPattern(for: pair.close)
            result = result.replacingOccurrences(
                of: "(?is)\(open)[\\s\\S]*?\(close)",
                with: "",
                options: .regularExpression)
            if let range = result.range(
                of: "(?is)\(open)[\\s\\S]*$",
                options: .regularExpression) {
                result.removeSubrange(range)
            }
        }
        // Qwen-style Chinese reasoning marker (思考): some uncensored/Chinese
        // finetunes delimit the reasoning preamble with 思考 … 思考 instead of
        // <think> tags. A complete pair proves the delimiter convention, so
        // the whole preamble through the closing marker is hidden. A lone
        // marker is ambiguous (the word also means "thinking" in ordinary
        // prose), so only the tail from the marker on is hidden — preceding
        // text stays visible and the message can never vanish entirely.
        // Each iteration removes at least one marker, so the loop is bounded.
        while let first = result.range(of: "思考") {
            let rest = result[first.upperBound...]
            if let close = rest.range(of: "思考") {
                result.removeSubrange(result.startIndex..<close.upperBound)
            } else {
                result.removeSubrange(first.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let reasoningTagPairs: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>"),
        ("<reasoning>", "</reasoning>"),
        ("<analysis>", "</analysis>"),
        ("<|thinking|>", "<|/thinking|>"),
        ("<|assistant_thought|>", "<|/assistant_thought|>"),
        ("[thinking]", "[/thinking]"),
    ]

    private static func thinkingBlocks(in text: String, includeUnterminated: Bool) -> [String] {
        var located: [(offset: Int, text: String)] = []
        for pair in reasoningTagPairs {
            var cursor = text.startIndex
            while let open = text.range(
                of: pair.open,
                options: [.caseInsensitive],
                range: cursor..<text.endIndex)
            {
                let search = open.upperBound..<text.endIndex
                if let close = text.range(
                    of: pair.close,
                    options: [.caseInsensitive],
                    range: search)
                {
                    let value = String(text[open.upperBound..<close.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        located.append((text.distance(from: text.startIndex, to: open.lowerBound), value))
                    }
                    cursor = close.upperBound
                } else {
                    if includeUnterminated {
                        let value = String(text[open.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty {
                            located.append((text.distance(from: text.startIndex, to: open.lowerBound), value))
                        }
                    }
                    break
                }
            }
        }

        located.append(contentsOf: channelThinkingBlocks(in: text, includeUnterminated: includeUnterminated))

        // Chinese models use a paired 思考 delimiter. Keep it in the same
        // ordered channel as XML-style markers.
        var markerRanges: [Range<String.Index>] = []
        var markerCursor = text.startIndex
        while let range = text.range(of: "思考", range: markerCursor..<text.endIndex) {
            markerRanges.append(range)
            markerCursor = range.upperBound
        }
        var markerIndex = 0
        while markerIndex + 1 < markerRanges.count {
            let start = markerRanges[markerIndex].upperBound
            let end = markerRanges[markerIndex + 1].lowerBound
            let value = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                located.append((text.distance(from: text.startIndex, to: markerRanges[markerIndex].lowerBound), value))
            }
            markerIndex += 2
        }
        if includeUnterminated, markerIndex < markerRanges.count {
            let value = String(text[markerRanges[markerIndex].upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                located.append((text.distance(from: text.startIndex, to: markerRanges[markerIndex].lowerBound), value))
            }
        }

        return located.sorted { $0.offset < $1.offset }.map(\.text)
    }

    /// Some OpenAI-compatible gateways preserve the model's internal
    /// channel protocol instead of translating it to `<think>` tags. The
    /// analysis channel is private model work; the final channel is the
    /// answer. Keep the markers out of both surfaces while retaining the
    /// analysis text for the reasoning card.
    private static let analysisChannel = "<|channel|>analysis<|message|>"
    private static let finalChannel = "<|channel|>final<|message|>"
    private static let channelEnd = "<|end|>"

    private static func channelThinkingBlocks(
        in text: String,
        includeUnterminated: Bool
    ) -> [(offset: Int, text: String)] {
        var result: [(offset: Int, text: String)] = []
        var cursor = text.startIndex
        while let open = text.range(
            of: analysisChannel,
            options: [.caseInsensitive],
            range: cursor..<text.endIndex)
        {
            let search = open.upperBound..<text.endIndex
            let final = text.range(of: finalChannel, options: [.caseInsensitive], range: search)
            let end = text.range(of: channelEnd, options: [.caseInsensitive], range: search)
            let boundary: Range<String.Index>? = [final, end]
                .compactMap { $0 }
                .min { $0.lowerBound < $1.lowerBound }

            if let boundary {
                let value = String(text[open.upperBound..<boundary.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    result.append((
                        text.distance(from: text.startIndex, to: open.lowerBound),
                        value))
                }
                cursor = boundary.upperBound
            } else {
                if includeUnterminated {
                    let value = String(text[open.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        result.append((
                            text.distance(from: text.startIndex, to: open.lowerBound),
                            value))
                    }
                }
                break
            }
        }
        return result
    }

    private static func hasOpenChannelThinkingBlock(_ text: String) -> Bool {
        guard let open = text.range(
            of: analysisChannel,
            options: [.caseInsensitive],
            range: text.startIndex..<text.endIndex)
        else { return false }
        let search = open.upperBound..<text.endIndex
        let final = text.range(of: finalChannel, options: [.caseInsensitive], range: search)
        let end = text.range(of: channelEnd, options: [.caseInsensitive], range: search)
        guard let boundary = [final, end].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return true }
        // A later analysis channel can reopen the state after a completed
        // channel; recurse on the suffix rather than treating the first one
        // as authoritative.
        let suffix = String(text[boundary.upperBound...])
        return hasOpenChannelThinkingBlock(suffix)
    }

    private static func strippingChannelThinking(_ text: String) -> String {
        var result = text
        var cursor = result.startIndex
        while let open = result.range(
            of: analysisChannel,
            options: [.caseInsensitive],
            range: cursor..<result.endIndex)
        {
            let search = open.upperBound..<result.endIndex
            let final = result.range(of: finalChannel, options: [.caseInsensitive], range: search)
            let end = result.range(of: channelEnd, options: [.caseInsensitive], range: search)
            let boundary: Range<String.Index>? = [final, end]
                .compactMap { $0 }
                .min { $0.lowerBound < $1.lowerBound }
            guard let boundary else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
            if boundary == final {
                // Keep the final channel's answer, then remove its marker in
                // the cleanup pass below.
                result.removeSubrange(open.lowerBound..<boundary.lowerBound)
                cursor = open.lowerBound
            } else {
                result.removeSubrange(open.lowerBound..<boundary.upperBound)
                cursor = open.lowerBound
            }
        }
        result = result.replacingOccurrences(
            of: finalChannel,
            with: "",
            options: [.caseInsensitive])
        result = result.replacingOccurrences(
            of: channelEnd,
            with: "",
            options: [.caseInsensitive])
        return result
    }
}
