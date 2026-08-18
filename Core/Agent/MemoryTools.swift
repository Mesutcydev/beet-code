import Foundation

/// Mem0-style memory maintenance tools. Registered only when memory mode is
/// enabled; the loop injects the current facts into the system prompt so the
/// model can decide what to add/update/delete.
struct MemoryAddTool: AgentTool {
    let name = "memory_add"
    let summary = "Store a durable fact about the project for future sessions"
    let risk = ToolRisk.write

    let schemaText = """
        {"type":"object","properties":{
          "fact":{"type":"string","description":"The fact to remember, as a concise statement"}
        },"required":["fact"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let fact = call.string("fact"), !fact.isEmpty else {
            throw ToolError.missingArgument("fact")
        }
        guard let memory = context.memory else {
            return "error: memory is disabled in Settings"
        }
        guard let stored = memory.addFact(fact, source: "memory_add") else {
            return "error: fact too short to store"
        }
        return "remembered: \(stored.text)"
    }
}

struct MemoryDeleteTool: AgentTool {
    let name = "memory_delete"
    let summary = "Forget a previously stored fact"
    let risk = ToolRisk.write

    let schemaText = """
        {"type":"object","properties":{
          "fact":{"type":"string","description":"The fact to forget (matches stored facts by text)"}
        },"required":["fact"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let fact = call.string("fact"), !fact.isEmpty else {
            throw ToolError.missingArgument("fact")
        }
        guard let memory = context.memory else {
            return "error: memory is disabled in Settings"
        }
        memory.deleteFact(text: fact)
        return "forgot: \(fact)"
    }
}