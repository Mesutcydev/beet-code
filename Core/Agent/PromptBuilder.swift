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
        projectPolicy: String? = nil,
        workspaceHistory: String? = nil,
        agentPrompt: String? = nil,
        planMode: Bool = false,
        goalMode: Bool = false,
        outputStyle: ProjectPolicy.OutputStyle = .normal,
        contextWindowTokens: Int? = nil,
        responseReserveTokens: Int = 4096,
        leanPrompt: Bool = false
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

        // Small local GGUF models are much more reliable when the lean
        // prompt contains one direct instruction surface. Goal mode is still
        // tracked by the controller, but its long-form prompt block can make
        // Llama-family models echo the tool protocol instead of answering.
        if goalMode && !leanPrompt {
            sections.append("""
            # Goal mode

            Stay focused on the user's complete goal. After the plan is
            approved, keep inspecting, editing, verifying, and correcting until
            the requested outcome is actually complete. Do not stop after a
            partial change; use attempt_completion only when the goal is done
            or a concrete blocker needs the user's input.
            """)
        }

        sections.append(outputStylePrompt(outputStyle))

        if !leanPrompt,
           let agentPrompt,
           !agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            sections.append("# Active agent profile\n\n\(bounded(agentPrompt, characters: 12_000))")
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

        if !leanPrompt {
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

        if let projectPolicy, !projectPolicy.isEmpty {
            sections.append("# Project policy\n\n\(bounded(projectPolicy, characters: 4_000))")
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
        } else {
            // Large local models on a memory-constrained Mac cannot afford a
            // full workspace index, project history, or capability catalog in
            // every prefill. Keep the direct-answer path explicit.
            sections.append("""
            # Lightweight local mode

            Answer ordinary questions directly when no file inspection or edit
            is needed. Do not call a tool just to be helpful. For coding work,
            use only the compact tool list above and keep each step focused.
            For a short request such as "Reply with exactly X", return exactly
            the requested text. Do not add greetings, identity statements,
            "Task complete", or a conclusion unless the user asks for them.
            Preserve the user's requested Markdown, line breaks, and code
            indentation in the answer.
            """)
        }

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

    private static func outputStylePrompt(_ style: ProjectPolicy.OutputStyle) -> String {
        switch style {
        case .concise:
            return """
            # Response style

            Keep the final answer concise. State what changed, the verification
            result, and any blocker or next action. Do not repeat the user's
            request or narrate routine tool calls.
            """
        case .normal:
            return """
            # Response style

            Use a balanced final answer: summarize the meaningful changes,
            mention verification, and explain any remaining caveat in plain
            language. Keep routine tool narration out of the final response.
            """
        case .detailed:
            return """
            # Response style

            Give a detailed final answer with the important design decisions,
            files or surfaces affected, verification performed, and any
            remaining caveat. Stay organized and avoid repeating raw logs.
            """
        }
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

            task runs one bounded nested agent (up to 8 turns) through this \
            session's approval gate. Pick a role explicitly:
            - research: read/search/list only; use it to map the codebase.
            - implement: write/apply/build tools; use it for a focused change.
            - verify: read plus the detected build/test checker; never edits.
            - review: read/diff/checks; report regressions and missing coverage.
            The agent field accepts OpenCode aliases such as reviewer or tester.
            Do not nest task calls. Child writes and commands still ask unless
            auto-approve is on, and implementation checks use the same
            verification setting as the parent.
            """)
        }

        if names.contains("create_macos_app") || names.contains("create_ios_app")
            || names.contains("build_diagnostics") || names.contains("macos_build_run") {
            blocks.append("""
            ## Delivering a native iOS or macOS app

            When the user asks you to create, build, run, or ship an Apple app, \
            stay in this loop until the app actually launches. Do not stop at \
            writing files.

            macOS:
            - Empty folder: `create_macos_app` (XcodeGen `project.yml` + SwiftUI skeleton).
            - After adding or removing Swift files: `run_command` `xcodegen generate`.
            - Deliver with `macos_build_run` (build + launch the .app). \
            `build_diagnostics` is the compile-only check.
            - If the window looks wrong, use `computer_ui_tree` / \
            `computer_screenshot` then `describe_image`.

            iOS:
            - Empty folder: `create_ios_app`.
            - After adding or removing Swift files: `xcodegen generate`.
            - Deliver with `sim_build_run` (build → install → launch → \
            screenshot → describe). Fix from diagnostics or the screenshot \
            and repeat until the screen is correct.
            - For finer control: `sim_list_devices` → `sim_boot_device` → \
            `sim_launch_app`, then `sim_tap` / `sim_describe`.

            Do not invent a pbxproj by hand. Stay in the workspace. Prefer \
            `apply_patch` for edits. Read before write.
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
        return joiningThinkingBlocks(blocks)
    }

    /// Streaming counterpart of `extractingThinking`: it also returns the
    /// currently open block so the live reasoning surface can update before a
    /// provider closes its thought section.
    static func extractingThinkingIncludingOpen(_ text: String) -> String {
        joiningThinkingBlocks(thinkingBlocks(in: text, includeUnterminated: true))
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

    /// Removes chat-template control tokens that can leak when a local model
    /// uses a different generation wrapper than the one it was fine-tuned
    /// with. The answer itself is left untouched so Markdown, code fences,
    /// indentation, and line breaks retain their original structure.
    static func strippingModelControlTokens(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?is)<\|start_header_id\|>\s*(?:system|user|assistant|tool)\s*<\|end_header_id\|>"#,
            #"(?is)<\|im_start\|>\s*(?:system|user|assistant|tool)\s*"#,
            #"<\|(?:eot_id|end_of_text|im_end|im_start|end|begin_of_text|start_of_turn|end_of_turn)\|>"#,
            #"<\|(?:start_header_id|end_header_id|assistant|user|system|tool)\|>"#,
            #"</?s>"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One cleanup path for every engine before text reaches the transcript
    /// or the persisted session. Tool syntax is handled separately because it
    /// must remain available to the agent loop's parser.
    static func cleaningGeneratedText(_ text: String) -> String {
        strippingModelControlTokens(strippingThinking(text))
    }

    /// Extracts the small, unambiguous exact-answer requests commonly used to
    /// smoke-test a local model. Some instruct finetunes answer those prompts
    /// conversationally (for example, "I'll."), so the agent can enforce the
    /// user's explicit contract without changing ordinary prose generation.
    static func exactRequestedAnswer(in request: String) -> String? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let prefixes = [
            "reply with exactly ",
            "respond with exactly ",
            "output exactly ",
            "return exactly ",
        ]
        guard let prefix = prefixes.first(where: { lowercased.hasPrefix($0) }) else {
            return nil
        }

        var answer = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The period in "Reply with exactly OK." is sentence punctuation for
        // the instruction, not part of the requested token. Remove it before
        // handling the equally common "and nothing else" suffix.
        if let last = answer.last, ".!?".contains(last) {
            answer.removeLast()
            answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let nothingElse = " and nothing else"
        if answer.lowercased().hasSuffix(nothingElse) {
            answer.removeLast(nothingElse.count)
            answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !answer.isEmpty, answer.count <= 512 else { return nil }
        return answer
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

    private struct ThinkingBlock {
        let offset: Int
        let endOffset: Int
        let text: String
    }

    private static func thinkingBlocks(in text: String, includeUnterminated: Bool) -> [ThinkingBlock] {
        var located: [ThinkingBlock] = []
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
                    let rawValue = String(text[open.upperBound..<close.lowerBound])
                    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        located.append(ThinkingBlock(
                            offset: text.distance(from: text.startIndex, to: open.lowerBound),
                            endOffset: text.distance(from: text.startIndex, to: close.upperBound),
                            text: rawValue))
                    }
                    cursor = close.upperBound
                } else {
                    if includeUnterminated {
                        let rawValue = String(text[open.upperBound...])
                        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty {
                            located.append(ThinkingBlock(
                                offset: text.distance(from: text.startIndex, to: open.lowerBound),
                                endOffset: text.count,
                                text: rawValue))
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
            let rawValue = String(text[start..<end])
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                located.append(ThinkingBlock(
                    offset: text.distance(from: text.startIndex, to: markerRanges[markerIndex].lowerBound),
                    endOffset: text.distance(from: text.startIndex, to: markerRanges[markerIndex + 1].upperBound),
                    text: rawValue))
            }
            markerIndex += 2
        }
        if includeUnterminated, markerIndex < markerRanges.count {
            let rawValue = String(text[markerRanges[markerIndex].upperBound...])
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                located.append(ThinkingBlock(
                    offset: text.distance(from: text.startIndex, to: markerRanges[markerIndex].lowerBound),
                    endOffset: text.count,
                    text: rawValue))
            }
        }

        return located.sorted { $0.offset < $1.offset }
    }

    /// Provider streams often encode each reasoning delta as its own complete
    /// `<think>…</think>` pair. Those pairs are adjacent in the accumulated
    /// wire text, so treating them as separate paragraphs turns a thought into
    /// one word per line. Keep real separated reasoning blocks readable, but
    /// join adjacent provider fragments as one continuous trace.
    private static func joiningThinkingBlocks(_ blocks: [ThinkingBlock]) -> String {
        var result = ""
        var previous: ThinkingBlock?

        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if result.isEmpty {
                result = trimmed
            } else if let previous, block.offset == previous.endOffset {
                result = appendingReasoningFragment(block.text, to: result)
            } else {
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + trimmed
            }
            previous = block
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendingReasoningFragment(_ fragment: String, to text: String) -> String {
        guard !text.isEmpty, !fragment.isEmpty else { return text + fragment }
        if text.last?.isWhitespace == true || fragment.first?.isWhitespace == true {
            return text + fragment
        }
        if let first = fragment.first,
           String(first).rangeOfCharacter(from: .punctuationCharacters) != nil {
            return text + fragment
        }
        return text + " " + fragment
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
    ) -> [ThinkingBlock] {
        var result: [ThinkingBlock] = []
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
                let rawValue = String(text[open.upperBound..<boundary.lowerBound])
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    result.append(ThinkingBlock(
                        offset: text.distance(from: text.startIndex, to: open.lowerBound),
                        endOffset: text.distance(from: text.startIndex, to: boundary.upperBound),
                        text: rawValue))
                }
                cursor = boundary.upperBound
            } else {
                if includeUnterminated {
                    let rawValue = String(text[open.upperBound...])
                    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        result.append(ThinkingBlock(
                            offset: text.distance(from: text.startIndex, to: open.lowerBound),
                            endOffset: text.count,
                            text: rawValue))
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
