import Foundation

/// Structured classification of tool failures so the model (and UI) can tell
/// a timeout from a bad command from a workspace refusal without parsing
/// prose. Rendered as a leading [tag] on failed observations.
enum ToolFailure: Equatable, Sendable {
    case unknownTool(String)
    case invalidArguments(String)
    case workspace(String)
    case timeout
    case commandFailed(Int32)
    case other(String)

    var tag: String {
        switch self {
        case .unknownTool: "[unknown tool]"
        case .invalidArguments: "[invalid arguments]"
        case .workspace: "[workspace]"
        case .timeout: "[timeout]"
        case .commandFailed(let code): "[command exit \(code)]"
        case .other: "[error]"
        }
    }
}
/// The only component that actually runs tool calls. It receives calls that
/// already passed the permission gate; failures are returned as observations
/// so the model can react to them instead of crashing the loop.
struct ToolExecutor {

    /// Structured outcome of one tool call, including the typed command
    /// result when the tool reports one.
    struct Outcome: Sendable, Equatable {
        var output: String
        var failed: Bool
        var exitCode: Int32? = nil
        var failure: ToolFailure? = nil
    }

    let tools: [String: any AgentTool]
    let context: ToolContext
    let cache: ToolResultCache

    init(tools: [any AgentTool], context: ToolContext, cache: ToolResultCache = .shared) {
        var map: [String: any AgentTool] = [:]
        // Duplicate registrations are a programming error: the last one
        // silently wins today, which hides tool-name collisions. Reject them.
        for tool in tools {
            precondition(map[tool.name] == nil, "duplicate tool registration: \(tool.name)")
            map[tool.name] = tool
        }
        self.tools = map
        self.context = context
        self.cache = cache
    }

    func tool(named name: String) -> (any AgentTool)? {
        tools[name]
    }

    func execute(_ call: ParsedToolCall) async -> Outcome {
        guard let tool = tools[call.name] else {
            let known = tools.keys.sorted().joined(separator: ", ")
            let message = "error: unknown tool '\(call.name)'. Available tools: \(known)"
            return Outcome(output: message, failed: true, failure: .unknownTool(call.name))
        }

        // ForgeCache action cache: fingerprint the invocation, reuse a valid
        // result, store a successful miss. Failures are never cached.
        if tool.cachePolicy != .never,
           let fingerprint = fingerprint(for: call, tool: tool) {
            let ttl = tool.cachePolicy.ttl
            if let cached = await cache.result(for: fingerprint, ttl: ttl) {
                tool.applyCacheHitSideEffects(for: call, in: context)
                return cached
            }
            let outcome = await executeUncached(call, tool: tool)
            if !outcome.failed {
                await cache.store(outcome, for: fingerprint, ttl: ttl)
            }
            return outcome
        }

        return await executeUncached(call, tool: tool)
    }

    private func executeUncached(_ call: ParsedToolCall, tool: any AgentTool) async -> Outcome {
        do {
            // Typed command path: failures are marked from exit code/timeout,
            // not from string-sniffing rendered output.
            if let commandTool = tool as? any CommandExecuting {
                let result = try await commandTool.executeCommand(call, in: context)
                let failure: ToolFailure? = result.timedOut
                    ? .timeout
                    : (result.exitCode != 0 ? .commandFailed(result.exitCode) : nil)
                return Outcome(
                    output: Self.prefix(failure, context.truncate(RunCommandTool.render(result))),
                    failed: result.failed,
                    exitCode: result.exitCode,
                    failure: failure)
            }
            let output = try await tool.execute(call, in: context)
            return Outcome(output: context.truncate(output), failed: false)
        } catch let error as ToolError {
            let failure: ToolFailure = Self.classify(error)
            return Outcome(
                output: Self.prefix(failure, "error: \(error.localizedDescription)"),
                failed: true,
                failure: failure)
        } catch {
            let failure = ToolFailure.other(error.localizedDescription)
            return Outcome(
                output: Self.prefix(failure, "error: \(error.localizedDescription)"),
                failed: true,
                failure: failure)
        }
    }

    /// Builds the action fingerprint for cacheable tools. Returns nil when the
    /// tool's inputs cannot be fully identified — no fingerprint, no caching.
    private func fingerprint(for call: ParsedToolCall, tool: any AgentTool) -> ActionFingerprint? {
        let workspaceHash = ContentDigest.sha256Hex(context.workspace.root.path)
        return ActionFingerprint(
            toolID: tool.name,
            toolVersion: tool.cacheVersion,
            canonicalArgumentsHash: ContentDigest.sha256Hex(call.argumentsJSON),
            workspaceSnapshotHash: workspaceHash,
            inputContentHashes: tool.cacheInputHashes(for: call, in: context))
    }

    // MARK: Classification

    private static func classify(_ error: ToolError) -> ToolFailure {
        switch error {
        case .timeout: .timeout
        case .commandFailed(let code): .commandFailed(Int32(code))
        case .missingArgument(let name): .invalidArguments(name)
        case .invalidWorkspaceRoot, .pathOutsideWorkspace, .notPreviouslyRead, .binaryFile, .fileTooLarge:
            .workspace(error.localizedDescription)
        }
    }

    private static func prefix(_ failure: ToolFailure?, _ message: String) -> String {
        guard let failure else { return message }
        let tag = failure.tag
        return message.hasPrefix(tag) ? message : tag + " " + message
    }
}