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
        planMode: Bool = false
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
                "# Workspace structure (bounded index)\n\n\(repoIndex.render)")
        }

        // Long-term memory: durable facts and earlier-session summaries. Like
        // the repo index, memory lives in the system prompt so compaction
        // never evicts it.
        if let memorySection {
            sections.append("# Memory\n\n\(memorySection)")
        }

        // Project conventions (AGENTS.md / CLAUDE.md): the project's own
        // instructions for agents — build commands, style rules, forbidden
        // paths. Loaded verbatim, bounded; lives in the prompt so compaction
        // never evicts it.
        if let projectInstructions, !projectInstructions.isEmpty {
            sections.append("# Project instructions (AGENTS.md / CLAUDE.md)\n\n\(projectInstructions)")
        }

        // Workspace history: what earlier sessions in THIS folder were about
        // — BeetCode's own and chats imported from Claude / Codex / Cursor.
        // Bounded digest; like memory it survives compaction in the prompt.
        if let workspaceHistory, !workspaceHistory.isEmpty {
            sections.append("# Earlier work in this workspace\n\n\(workspaceHistory)")
        }

        sections.append("""
        # Conventions for editing files

        Prefer `apply_patch` with SEARCH/REPLACE blocks for edits. SEARCH text \
        must match the file exactly, character-for-character, including \
        indentation. Include just enough surrounding lines to make the match \
        unique. Use `write_file` only for new files or complete rewrites. You \
        must read a file before editing it.
        """)

        return sections.joined(separator: "\n\n")
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

        guard !blocks.isEmpty else { return nil }
        return "# Built-in browser & simulator\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Extracts the concatenated reasoning blocks (e.g. Qwen3
    /// <think>…</think>) from raw generation, if any.
    static func extractingThinking(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<think>\s*([\s\S]*?)\s*</think>"#)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let blocks = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let blockRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[blockRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !blocks.isEmpty else { return nil }
        return blocks.joined(separator: "\n\n")
    }
    /// Strips reasoning blocks (e.g. Qwen3 `<think>…</think>`) before the text
    /// is parsed for tool calls or shown as a final answer.
    static func strippingThinking(_ text: String) -> String {
        var result = text
        // Complete blocks.
        result = result.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: "",
            options: .regularExpression)
        // Unterminated block (generation cut mid-think).
        if let range = result.range(of: #"<think>[\s\S]*$"#, options: .regularExpression) {
            result.removeSubrange(range)
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
}