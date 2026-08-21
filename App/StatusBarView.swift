import SwiftUI

/// Status bar: monospaced digits, consistent units, chip-style segments with
/// generous spacing — scannable at a glance instead of a run-on sentence.
struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            statusRow(includeSecondary: true)
            statusRow(includeSecondary: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .background(Theme.bg)
    }

    @ViewBuilder
    private func statusRow(includeSecondary: Bool) -> some View {
        HStack(spacing: 10) {
            chip(icon: appState.activeModelID == nil ? "cpu" : "checkmark.seal",
                 tint: appState.activeModelID == nil ? Theme.textSecondary : Theme.success) {
                Text(appState.activeModel?.displayName ?? "No model")
                    .lineLimit(1)
            }
            .help(appState.isRemoteActive ? "Active remote (BYOK) engine" : "Active local MLX model")
            .layoutPriority(2)

            chip(icon: "memorychip", tint: Theme.info) {
                Text(ByteFormatter.bytes(appState.currentFootprint))
                    .monospacedDigit()
                Text("/")
                    .foregroundStyle(Theme.textTertiary)
                Text(ByteFormatter.bytes(appState.availableBudget))
                    .monospacedDigit()
            }
            .help("Process footprint vs. remaining model budget.")
            .layoutPriority(1)

            thermalChip
            cpuChip
            runPhaseChip

            IntelligenceInspectorButton()

            Spacer(minLength: 0)

            if includeSecondary, let tps = appState.lastEngineStats.tokensPerSecond {
                chip(icon: "speedometer", tint: Theme.accent) {
                    Text(String(format: "%.1f", tps))
                        .monospacedDigit()
                    Text("tok/s")
                        .foregroundStyle(Theme.textTertiary)
                }
                .help("Tokens per second from the last generation")
            }

            if includeSecondary, appState.sessionUsage.totalTokens > 0 {
                let label = appState.sessionUsage.compactLabel(
                    provider: appState.engine.activeRemoteEndpoint?.provider)
                chip(icon: "sum", tint: Theme.info) {
                    Text(label)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .help("This chat: \(appState.sessionUsage.promptTokens) prompt + \(appState.sessionUsage.completionTokens) completion tokens across \(appState.sessionUsage.turns) generation(s). Cost is a published-rate estimate, not a bill.")
            }
        }
    }

    /// Thermal state only — never a percentage, so nobody reads it as a
    /// temperature reading.
    private var thermalChip: some View {
        let state = appState.thermal.effectiveState
        return chip(icon: state.uiIcon, tint: color(for: state)) {
            Text(state.uiLabel)
        }
        .help("Thermal state merges the kernel thermal state with a sustained-CPU-load proxy (sustained load escalates even when the kernel reports nominal). Serious caps tokens per turn; critical blocks model loads.")
    }

    /// Whole-machine CPU load. Hidden while the machine is idle so the bar
    /// stays model + phase + RAM first.
    @ViewBuilder
    private var cpuChip: some View {
        let busy = appState.thermal.cpuBusyFraction
        let elevated = appState.thermal.effectiveState != .nominal || busy > 0.35
        if elevated {
            chip(icon: "gauge.medium", tint: Theme.textSecondary) {
                Text("CPU")
                Text(String(format: "%d%%", Int(busy * 100)))
                    .monospacedDigit()
            }
            .help("Whole-machine CPU load averaged over the last ~30 seconds.")
        }
    }

    /// A small native status lane for the agent state. It makes the chat's
    /// current phase visible even when the transcript is scrolled away, and
    /// uses the system progress affordance instead of another busy animation.
    @ViewBuilder
    private var runPhaseChip: some View {
        if appState.sessions.isRunning || appState.sessions.pendingApproval != nil
            || appState.sessions.pendingQuestion != nil || appState.sessions.pendingPlan != nil {
            let phase = appState.sessions.currentPhase
            chip(icon: phaseIcon(phase), tint: phaseColor(phase)) {
                if appState.sessions.isRunning {
                    ProgressView().controlSize(.mini)
                }
                Text(phaseLabel(phase))
            }
            .help("Agent phase: \(phaseLabel(phase))")
            .accessibilityLabel("Agent phase: \(phaseLabel(phase))")
            .layoutPriority(2)
        }
    }

    private func phaseLabel(_ phase: AgentPhase) -> String {
        switch phase {
        case .planning: "Planning"
        case .awaitingPlanApproval: "Plan ready"
        case .working: "Working"
        case .awaitingApproval: "Needs approval"
        case .awaitingQuestion: "Needs an answer"
        case .verifying: "Verifying"
        case .finished: "Finishing"
        case .idle: "Idle"
        }
    }

    private func phaseIcon(_ phase: AgentPhase) -> String {
        switch phase {
        case .planning, .awaitingPlanApproval: "list.bullet.clipboard"
        case .awaitingApproval: "hand.raised.fill"
        case .awaitingQuestion: "questionmark.circle.fill"
        case .verifying: "checkmark.shield"
        case .working: "sparkles"
        case .finished: "checkmark.circle"
        case .idle: "circle"
        }
    }

    private func phaseColor(_ phase: AgentPhase) -> Color {
        switch phase {
        case .awaitingApproval, .awaitingQuestion: Theme.warning
        case .verifying: Theme.info
        case .finished: Theme.success
        default: Theme.accent
        }
    }

    private func chip<Content: View>(
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
            content()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.surfaceInset.opacity(0.6), in: Capsule())
    }

    private func color(for state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: Theme.success
        case .fair: Theme.warning
        case .serious: Theme.warning
        case .critical: Theme.danger
        @unknown default: Theme.textSecondary
        }
    }
}
