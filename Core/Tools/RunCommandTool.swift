import Foundation
import os

/// Marker for tools that can report a structured command outcome so
/// ToolExecutor marks failures from facts (exit code / timeout) instead of
/// string-sniffing rendered output.
protocol CommandExecuting {
    func executeCommand(_ call: ParsedToolCall, in context: ToolContext) async throws -> CommandResult
}

/// Runs a shell command in the workspace with a timeout, capturing combined
/// output. Every invocation requires permission-gate approval (or an
/// allowlisted exact form when the user enabled safe auto-approve).
/// Arbitrary `/bin/zsh -c` text remains available only behind an explicit
/// approval card — never auto-approved.
struct RunCommandTool: AgentTool, CommandExecuting {
    let name = "run_command"
    let summary = "Run a shell command in the workspace directory"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "command":{"type":"string","description":"Shell command line (zsh)"},
          "timeout":{"type":"integer","description":"Seconds before the command is killed (default 120, max 600)"}
        },"required":["command"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let command = call.string("command") else { return .none }
        return .command(command)
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let result = try await executeCommand(call, in: context)
        return Self.render(result)
    }

    func executeCommand(_ call: ParsedToolCall, in context: ToolContext) async throws -> CommandResult {
        guard let command = call.string("command"), !command.isEmpty else {
            throw ToolError.missingArgument("command")
        }
        let timeout = min(max(call.int("timeout") ?? 120, 1), 600)

        let workspace = context.workspace
        // The runner blocks synchronously, so cancellation is signalled
        // through a flag the runner polls; the whole process group then gets
        // SIGKILL and no child process survives the tool call. Both the
        // enclosing task cancellation and the loop's own cancel() (which sets
        // the context flag) kill the process group.
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        return try await withTaskCancellationHandler {
            // .userInitiated, NOT .utility: the interactive agent loop awaits
            // this at user-initiated QoS. A lower-priority detached task
            // triggers the Thread Performance Checker's priority-inversion
            // warning, whose inline CoreSymbolication can wedge the awaiting
            // main thread (observed as a deterministic hang). Running the
            // command at the same QoS as its waiter removes the inversion —
            // and is the right priority for a user-facing command anyway.
            try await Task.detached(priority: .userInitiated) {
                try ShellRunner.run(
                    command: command,
                    workingDirectory: workspace.root,
                    timeout: Double(timeout),
                    cancelCheck: {
                        cancelled.withLock { $0 } || context.isCancellationRequested
                    })
            }.value
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Renders a typed result the way the agent expects to see it.
    static func render(_ result: CommandResult) -> String {
        let body = truncate(result.output)
        if result.timedOut {
            return "error: command timed out\npartial output:\n\(body)"
        }
        if result.exitCode == 0 {
            return body.isEmpty ? "(no output, exit 0)" : body
        }
        return "exit status \(result.exitCode)\n\(body)"
    }

    static func truncate(_ output: String, limit: Int = 16_384) -> String {
        guard output.utf8.count > limit else { return output }
        let head = String(output.prefix(limit / 2))
        let tail = String(output.suffix(limit / 4))
        return head + "\n…[output truncated]…\n" + tail
    }
}