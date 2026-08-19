import SwiftUI

/// Phase 17 — loads the inspector model for the active workspace. Reads
/// the on-disk intelligence stores directly (read-mostly; WAL permits
/// concurrent readers) and assembles the pure model on a background task.
@MainActor
final class IntelligenceInspectorController: ObservableObject {
    @Published private(set) var model: IntelligenceInspectorModel?
    @Published private(set) var isLoading = false

    /// The packet of the most recent compiled request, when the agent
    /// pipeline provides one. Drives the "context for current request"
    /// section; absent → that section stays hidden, honestly.
    @Published var lastPacket: ContextPacket?

    func load(workspaceRoot: URL) async {
        isLoading = true
        let packet = lastPacket
        let assembled = await Task.detached(priority: .userInitiated) {
            Self.assemble(workspaceRoot: workspaceRoot, lastPacket: packet)
        }.value
        model = assembled
        isLoading = false
    }

    nonisolated private static func assemble(
        workspaceRoot: URL, lastPacket: ContextPacket?
    ) -> IntelligenceInspectorModel {
        let identity = WorkspaceIdentity.resolve(root: workspaceRoot)
        let projectName = workspaceRoot.lastPathComponent
        let graphURL = IntelligenceStoreLayout.graphDatabase(for: identity.workspaceID)

        guard FileManager.default.fileExists(atPath: graphURL.path),
              let graph = try? SymbolGraph(store: SQLiteStore(url: graphURL))
        else {
            return IntelligenceInspectorModel(
                projectName: projectName, status: .unavailable,
                domains: [], requestRows: [], requestTotal: 0, itemDetails: [])
        }

        let metadataURL = IntelligenceStoreLayout.metadataDatabase(for: identity.workspaceID)
        let entities = try? EntityStore(store: SQLiteStore(url: graphURL))
        let knowledge = FileManager.default.fileExists(atPath: metadataURL.path)
            ? try? KnowledgeStore(store: SQLiteStore(url: metadataURL)) : nil
        let journal = FileManager.default.fileExists(atPath: metadataURL.path)
            ? try? InvalidationJournal(store: SQLiteStore(url: metadataURL)) : nil

        var working: WorkingState?
        if let branch = GitReader.read(workspaceRoot: workspaceRoot)?.branch,
           FileManager.default.fileExists(atPath: metadataURL.path),
           let store = try? WorkingStateStore(store: SQLiteStore(url: metadataURL)) {
            working = try? store.latest(workspaceID: identity.workspaceID, branch: branch)
        }

        let snapshot = WorkspaceSnapshotStore.shared.loadLatest(workspaceID: identity.workspaceID)
        var pending = 0
        if let snapshot, let journal {
            pending = (try? journal.changedPaths(since: snapshot.createdAt).count) ?? 0
        }
        let status = IntelligenceInspectorBuilder.status(
            lastSnapshotAt: snapshot?.createdAt, pendingChanges: pending)

        let domains = (try? IntelligenceInspectorBuilder.domains(
            graph: graph, knowledge: knowledge, entities: entities,
            workingState: working)) ?? []

        var rows: [RequestContextRow] = []
        var details: [ContextItemDetail] = []
        var total = 0
        if let lastPacket {
            let breakdown = IntelligenceInspectorBuilder.requestBreakdown(packet: lastPacket)
            rows = breakdown.rows
            details = breakdown.details
            total = breakdown.total
        }

        return IntelligenceInspectorModel(
            projectName: projectName, status: status, domains: domains,
            requestRows: rows, requestTotal: total, itemDetails: details)
    }
}

/// Project-bar pill: `Intelligence ● Fresh`. Opens the full inspector.
struct IntelligenceStatusPill: View {
    let status: IntelligenceFreshness

    private var dotColor: Color {
        switch status {
        case .fresh: Theme.success
        case .stale: Theme.warning
        case .indexing: Theme.info
        case .unavailable: Theme.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text("Intelligence")
            Text(status.label)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.surfaceInset.opacity(0.6), in: Capsule())
    }
}

/// The full inspector popover: domain summaries, then the current request's
/// context breakdown with per-item provenance. Dense and monospaced where
/// numbers are involved — a developer tool, not a dashboard.
struct IntelligenceInspectorView: View {
    @ObservedObject var controller: IntelligenceInspectorController
    let workspaceRoot: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let model = controller.model {
                header(model)
                Divider().overlay(Theme.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        domainSection(model)
                        if !model.requestRows.isEmpty {
                            requestSection(model)
                        }
                    }
                    .padding(14)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.isLoading ? "Indexing…" : "Loading…")
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(24)
            }
        }
        .frame(width: 420, height: 520)
        .background(Theme.bg)
        .task(id: workspaceRoot) {
            await controller.load(workspaceRoot: workspaceRoot)
        }
    }

    private func header(_ model: IntelligenceInspectorModel) -> some View {
        HStack(spacing: 8) {
            Text(model.projectName)
                .font(.headline)
            Spacer()
            IntelligenceStatusPill(status: model.status)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func domainSection(_ model: IntelligenceInspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROJECT INTELLIGENCE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            ForEach(model.domains) { domain in
                HStack(spacing: 8) {
                    Circle()
                        .fill(domain.freshness == .fresh ? Theme.success
                              : domain.freshness == .stale ? Theme.warning
                              : Theme.textTertiary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(domain.name)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(domain.detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.callout)
            }
        }
    }

    private func requestSection(_ model: IntelligenceInspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CONTEXT FOR CURRENT REQUEST")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            ForEach(model.requestRows) { row in
                HStack {
                    Text(row.label)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(row.tokens.formatted())
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.callout)
            }
            Divider().overlay(Theme.hairline)
            HStack {
                Text("Total").font(.callout.weight(.semibold))
                Spacer()
                Text(model.requestTotal.formatted())
                    .font(.callout.weight(.semibold).monospacedDigit())
            }

            if !model.itemDetails.isEmpty {
                Text("ITEMS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 6)
                ForEach(model.itemDetails) { item in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            provenance("why", item.whyIncluded)
                            provenance("source", item.section)
                            provenance("confidence", item.confidence)
                            provenance("freshness", item.freshness)
                            provenance("tokens", item.tokens.formatted())
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func provenance(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
    }
}

/// Status-bar entry point: pill button + popover inspector. Hidden when no
/// workspace is active — an inspector without a workspace would be fiction.
struct IntelligenceInspectorButton: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var controller = IntelligenceInspectorController()
    @State private var isOpen = false

    var body: some View {
        if let workspace = appState.preferences.validatedWorkspaceURL() {
            Button { isOpen.toggle() } label: {
                IntelligenceStatusPill(
                    status: controller.model?.status ?? (controller.isLoading ? .indexing : .unavailable))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                IntelligenceInspectorView(controller: controller, workspaceRoot: workspace)
            }
            .help("Workspace intelligence status and context inspector")
            .onAppear {
                Task { await controller.load(workspaceRoot: workspace) }
            }
        }
    }
}
