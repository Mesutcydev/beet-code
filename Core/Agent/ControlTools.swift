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
    let summary = "Delegate a focused subtask to a nested agent (reads + edits + shell, 8 turns, same approval gate)"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "prompt":{"type":"string","description":"The subtask for the nested agent — be specific"}
        },"required":["prompt"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        throw ToolError.missingArgument("prompt")
    }
}