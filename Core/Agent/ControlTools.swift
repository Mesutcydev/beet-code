import Foundation

/// Control-flow tools the loop handles itself (never executed by the
/// executor). They are declared as real tools so the system prompt, the
/// parser, and the permission gate all agree on their schemas.
enum ControlTools {

    static let names: Set<String> = [askUser.name, attemptCompletion.name, task.name]

    static let askUser = AskUserTool()
    static let attemptCompletion = AttemptCompletionTool()
    static let task = TaskTool()
}

/// Explicit capabilities for a nested agent. Roles keep delegation useful
/// without giving every research question write and shell access.
enum SubagentRole: String, Sendable, CaseIterable {
    case research
    case implement
    case verify
    case review

    var displayName: String {
        rawValue.capitalized
    }

    var allowsWrites: Bool {
        self == .implement
    }

    var runsProjectChecks: Bool {
        self == .implement || self == .verify || self == .review
    }

    var prompt: String {
        switch self {
        case .research:
            return """
            You are a research subagent. Inspect and explain the workspace using
            read/search/list tools only. Do not edit files, run commands, or claim
            that an implementation is complete. Return concrete findings and
            suggested next steps to the parent agent.
            """
        case .implement:
            return """
            You are an implementation subagent. Make the requested focused
            change using the available write tools, keep changes inside the
            workspace, and run the detected project checks after edits when
            available. Return changed files, check results, and any unresolved
            issue to the parent agent.
            """
        case .verify:
            return """
            You are a verification subagent. Inspect the current changes and run
            the detected build/test checks. Do not modify files. Report the exact
            check command, pass/fail result, and the smallest useful repair
            recommendation.
            """
        case .review:
            return """
            You are a review subagent. Inspect the current diff and surrounding
            code, then run the detected build/test checks when useful. Do not
            modify files. Look for regressions, unsafe behavior, missing tests,
            and user-visible issues; report findings by priority.
            """
        }
    }

    /// Accepts OpenCode-style agent names as well as the native role names.
    static func resolve(_ raw: String?) -> SubagentRole {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "research", "explore", "readonly", "read-only", "analyst":
            return .research
        case "verify", "verification", "test", "tester":
            return .verify
        case "review", "reviewer", "audit":
            return .review
        default:
            return .implement
        }
    }
}

/// Suspends the loop until the user answers a question.
struct AskUserTool: AgentTool {
    let name = "ask_user"
    let summary = "Ask the user a question when you need information only they can provide"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "question":{"type":"string","description":"The question to ask the user"}
        },"required":["question"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        // The loop intercepts this tool before execution; reaching here is a
        // programming error.
        throw ToolError.missingArgument("question")
    }
}

/// Signals that the task is complete.
struct AttemptCompletionTool: AgentTool {
    let name = "attempt_completion"
    let summary = "Report that the task is complete, with a short summary of what changed"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "result":{"type":"string","description":"Short summary of what was done"}
        },"required":["result"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        // The loop intercepts this tool before execution.
        throw ToolError.missingArgument("result")
    }
}

/// Spawns a bounded read-only child loop. The parent loop intercepts this
/// before execution — `execute` is never reached.
struct TaskTool: AgentTool {
    let name = "task"
    let summary = "Delegate a focused research, implementation, verification, or review subtask"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "prompt":{"type":"string","description":"The subtask for the nested agent — be specific"},
          "role":{"type":"string","enum":["research","implement","verify","review"],"description":"Delegated capability profile; defaults to implement for compatibility"},
          "agent":{"type":"string","description":"Optional OpenCode-compatible role alias (for example reviewer or tester)"}
        },"required":["prompt"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        throw ToolError.missingArgument("prompt")
    }
}
