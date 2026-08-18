import Foundation

/// Explicit task state machine for the agent loop. The UI can render a
/// current-phase indicator instead of inferring state from events.
enum AgentPhase: String, Sendable, Equatable {
    case idle
    case planning
    case awaitingPlanApproval
    case working
    case awaitingApproval
    case awaitingQuestion
    case verifying
    case finished
}
/// Events the agent loop emits to the UI. The UI reacts; it never drives the
/// loop's internals.
enum AgentEvent: Sendable, Equatable {
    case taskStarted
    case tokenDelta(String)
    /// Complete assistant message with `<think>` blocks stripped.
    case assistantMessage(String)
    case toolCallStarted(ToolInvocation)
    case awaitingApproval(ApprovalRequest)
    case toolCallFinished(ToolInvocation, output: String, failed: Bool)
    case askUser(UUID, String)
    case checkpointCreated(SessionCheckpoint)
    /// The checkpoint could not be taken before an approved mutation; the
    /// mutation was NOT executed.
    case checkpointFailed(String)
    /// The model violated the tool protocol (e.g. multiple calls per reply);
    /// the observation was fed back and the loop continues.
    case protocolError(String)
    /// Chain-of-thought extracted from the raw generation (shown only when
    /// the user enables reasoning).
    case reasoning(String)
    /// Plan mode: the model's plan, awaiting user approval.
    case planProposed(String)
    /// The task state machine advanced.
    case phaseChanged(AgentPhase)
    case finished(AgentFinish)
}

enum AgentFinish: Sendable, Equatable {
    case completed(String)
    case maxTurnsReached(Int)
    case declined(String)
    case cancelled
    case engineError(String)

    var isFailure: Bool {
        switch self {
        case .completed: false
        default: true
        }
    }

    /// Stable label for Stop hooks — case name only, no user prose.
    var hookReason: String {
        switch self {
        case .completed: "completed"
        case .maxTurnsReached: "max_turns"
        case .declined: "declined"
        case .cancelled: "cancelled"
        case .engineError: "engine_error"
        }
    }
}

/// One tool invocation as shown in the transcript.
struct ToolInvocation: Sendable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let argumentsJSON: String
    let summary: String

    init(call: ParsedToolCall, summary: String) {
        self.id = UUID()
        self.name = call.name
        self.argumentsJSON = call.argumentsJSON
        self.summary = summary
    }
}

/// What the permission gate needs to show the user before a risky action.
struct ApprovalRequest: Sendable, Identifiable, Equatable {
    let id: UUID
    let invocation: ToolInvocation
    let preview: ApprovalPreview
}

/// A user's answer to a proposed plan.
enum PlanDecision: Sendable, Equatable {
    case approve
    case revise(String)
    case cancel
}

/// Pending interactive requests the loop is suspended on.
enum PendingRequest {
    case approval(ApprovalRequest, CheckedContinuation<Bool, Never>)
    case question(UUID, String, CheckedContinuation<String, Never>)
    case plan(String, CheckedContinuation<PlanDecision, Never>)
}