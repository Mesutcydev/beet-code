import AppKit
import SwiftUI

/// In-app diagnostics panel: a filterable breadcrumb timeline plus a system
/// snapshot, docked like the browser/simulator panels. Export writes a
/// plain-text log for bug reports. See docs/DIAGNOSTICS-SPEC.md.
struct DiagnosticsPanelView: View {
    @ObservedObject private var center = DiagnosticsCenter.shared
    @State private var categoryFilter: DiagnosticsCenter.Breadcrumb.Category?
    /// Called when the user closes the side panel (there is no other way out).
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            systemSnapshot
            Divider()
            filterRow
            Divider()
            timeline
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Diagnostics", systemImage: "stethoscope")
                .font(.callout.weight(.semibold))
            if center.problemCount > 0 {
                Text("\(center.problemCount)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.danger, in: Capsule())
                    .help("\(center.problemCount) warnings or errors recorded")
            }
            Spacer()
            Button { center.clear() } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Clear all breadcrumbs")
            Button { exportLog() } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .controlSize(.small)
            .help("Export diagnostics log for a bug report")
            if let onClose {
                PanelCloseButton(action: onClose)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    // MARK: System snapshot

    private var systemSnapshot: some View {
        let info = center.systemInfo
        return HStack(spacing: Spacing.sm) {
            snapshotItem("app", info.appVersion)
            snapshotItem("os", info.macOSVersion)
            snapshotItem("mem", info.physicalMemory)
            snapshotItem("thermal", info.thermalState)
            snapshotItem("up", info.uptime)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func snapshotItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    // MARK: Filter pills

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                pill(nil, label: "All", icon: "line.3.horizontal.decrease",
                     count: center.breadcrumbs.count)
                ForEach(categoriesPresent, id: \.self) { category in
                    pill(category, label: category.label, icon: category.icon,
                         count: center.breadcrumbs.filter { $0.category == category }.count)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private var categoriesPresent: [DiagnosticsCenter.Breadcrumb.Category] {
        DiagnosticsCenter.Breadcrumb.Category.allCases.filter { category in
            center.breadcrumbs.contains { $0.category == category }
        }
    }

    private func pill(_ category: DiagnosticsCenter.Breadcrumb.Category?,
                      label: String, icon: String, count: Int) -> some View {
        let isActive = categoryFilter == category
        return Button {
            categoryFilter = category
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(.caption2.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isActive ? Theme.washStrong(Theme.accent) : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(
                isActive ? Theme.washBorder(Theme.accent) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Timeline

    private var filtered: [DiagnosticsCenter.Breadcrumb] {
        let all = categoryFilter == nil
            ? center.breadcrumbs
            : center.breadcrumbs.filter { $0.category == categoryFilter }
        return all.reversed()
    }

    private var timeline: some View {
        ScrollView {
            if filtered.isEmpty {
                Text(center.breadcrumbs.isEmpty
                     ? "No events yet — breadcrumbs appear as the app works."
                     : "No \(categoryFilter?.label.lowercased() ?? "") events.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { crumb in
                        row(crumb)
                    }
                }
                .padding(8)
            }
        }
    }

    private func row(_ crumb: DiagnosticsCenter.Breadcrumb) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(crumb.date, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 62, alignment: .leading)
            Image(systemName: crumb.category.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint(for: crumb.level))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(crumb.message)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = crumb.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            crumb.level == .error ? Theme.wash(Theme.danger) : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    private func tint(for level: DiagnosticsCenter.Breadcrumb.Level) -> Color {
        switch level {
        case .info: Theme.textSecondary
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }

    // MARK: Export

    private func exportLog() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.prompt = "Export"
        panel.nameFieldStringValue = DiagnosticsCenter.suggestedExportName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try center.exportText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
