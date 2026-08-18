import SwiftUI

/// Status bar: monospaced digits, consistent units, chip-style segments with
/// generous spacing — scannable at a glance instead of a run-on sentence.
struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            chip(icon: appState.activeModelID == nil ? "cpu" : "checkmark.seal",
                 tint: appState.activeModelID == nil ? Theme.textSecondary : Theme.success) {
                Text(appState.activeModel?.displayName ?? "No model")
            }
            .help(appState.isRemoteActive ? "Active remote (BYOK) engine" : "Active local MLX model")

            chip(icon: "memorychip", tint: Theme.info) {
                Text(ByteFormatter.bytes(appState.currentFootprint))
                    .monospacedDigit()
                Text("/")
                    .foregroundStyle(Theme.textTertiary)
                Text(ByteFormatter.bytes(appState.availableBudget))
                    .monospacedDigit()
                Text("budget")
                    .foregroundStyle(Theme.textTertiary)
            }
            .help("Process footprint vs. remaining model budget (70% of RAM reserved for models, minus current use).")

            thermalChip

            Spacer()

            if let tps = appState.lastEngineStats.tokensPerSecond {
                chip(icon: "speedometer", tint: Theme.accent) {
                    Text(String(format: "%.1f", tps))
                        .monospacedDigit()
                    Text("tok/s")
                        .foregroundStyle(Theme.textTertiary)
                }
                .help("Tokens per second from the last generation")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var thermalChip: some View {
        let state = appState.thermal.effectiveState
        let busy = appState.thermal.cpuBusyFraction
        return chip(icon: state.uiIcon, tint: color(for: state)) {
            Text(state.uiLabel)
            if busy > 0 {
                Text(String(format: "%d%%", Int(busy * 100)))
                    .monospacedDigit()
            }
        }
        .help("Thermal state merges the kernel thermal state with a CPU-load proxy (sustained load escalates even when the kernel reports nominal). Serious caps tokens per turn; critical blocks model loads.")
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
