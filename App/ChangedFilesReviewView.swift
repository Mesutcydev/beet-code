import Observation
import SwiftUI

@MainActor
@Observable
final class ChangedFilesReviewModel {
    let workspace: URL
    var files: [GitReviewFile] = []
    var selectedPath: String?
    var isLoading = false
    var errorMessage: String?
    private(set) var acceptedHunkIDs: Set<String> = []
    private(set) var rejectedCount = 0
    private(set) var checkpoint: SessionCheckpoint?

    init(workspace: URL) {
        self.workspace = workspace
    }

    var selectedFile: GitReviewFile? {
        files.first(where: { $0.path == selectedPath }) ?? files.first
    }

    var hunkCount: Int {
        files.reduce(0) { $0 + $1.hunks.count }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let workspace = workspace
            let loaded = try await Task.detached(priority: .userInitiated) {
                try GitReviewService.load(workspace: workspace)
            }.value
            files = loaded
            if let selectedPath, loaded.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = selectedPath
            } else {
                selectedPath = loaded.first?.path
            }
        } catch {
            files = []
            selectedPath = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func accept(_ hunk: GitReviewHunk) {
        acceptedHunkIDs.insert(hunk.id)
    }

    func reject(_ hunk: GitReviewHunk, in file: GitReviewFile) async {
        isLoading = true
        errorMessage = nil
        do {
            let workspace = workspace
            if checkpoint == nil {
                checkpoint = try await Task.detached(priority: .userInitiated) {
                    try GitReviewService.makeCheckpoint(workspace: workspace)
                }.value
            }
            try await Task.detached(priority: .userInitiated) {
                try GitReviewService.reject(hunk: hunk, in: file, workspace: workspace)
            }.value
            acceptedHunkIDs.remove(hunk.id)
            rejectedCount += 1
            await load()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func restoreCheckpoint() async {
        guard let checkpoint else { return }
        isLoading = true
        errorMessage = nil
        do {
            let workspace = workspace
            try await Task.detached(priority: .userInitiated) {
                try GitReviewService.restore(checkpoint, workspace: workspace)
            }.value
            acceptedHunkIDs = []
            rejectedCount = 0
            self.checkpoint = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

struct ChangedFilesReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChangedFilesReviewModel

    init(workspace: URL) {
        _model = State(initialValue: ChangedFilesReviewModel(workspace: workspace))
    }

    var body: some View {
        @Bindable var review = model

        NavigationSplitView {
            VStack(spacing: 0) {
                reviewSummary
                Divider().overlay(Theme.hairline)
                List(model.files, selection: $review.selectedPath) { file in
                    GitReviewFileRow(
                        path: file.path,
                        status: file.statusLabel,
                        isStaged: file.isStaged,
                        added: file.diff.addedCount,
                        removed: file.diff.removedCount)
                        .tag(file.path)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            GitReviewDetail(
                file: model.selectedFile,
                acceptedHunkIDs: model.acceptedHunkIDs,
                isBusy: model.isLoading,
                onAccept: model.accept,
                onReject: { hunk, file in
                    Task { await model.reject(hunk, in: file) }
                })
        }
        .background(Theme.bg)
        .frame(minWidth: 860, idealWidth: 1_080, minHeight: 580, idealHeight: 720)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if model.checkpoint != nil {
                    Button {
                        Task { await model.restoreCheckpoint() }
                    } label: {
                        Label("Restore review checkpoint", systemImage: "arrow.uturn.backward.circle")
                    }
                    .help("Undo every rejection made in this review")
                }
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                Button("Done") { dismiss() }
            }
        }
        .overlay {
            if model.isLoading, model.files.isEmpty {
                ProgressView("Loading changes…")
                    .padding(Spacing.xl)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.lg))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface)
            }
        }
        .task { await model.load() }
    }

    private var reviewSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Label("Changed files", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text("\(model.files.count) files · \(model.hunkCount) hunks")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if model.rejectedCount > 0 {
                Text("\(model.rejectedCount) rejected · checkpoint available")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            } else {
                Text("Accept keeps a hunk. Reject edits the working copy after creating an undo checkpoint.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.md)
    }
}

private struct GitReviewFileRow: View {
    let path: String
    let status: String
    let isStaged: Bool
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.text")
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(status)
                    if isStaged { Text("Staged") }
                    Text("+\(added)").foregroundStyle(Theme.success)
                    Text("−\(removed)").foregroundStyle(Theme.danger)
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct GitReviewDetail: View {
    let file: GitReviewFile?
    let acceptedHunkIDs: Set<String>
    let isBusy: Bool
    let onAccept: (GitReviewHunk) -> Void
    let onReject: (GitReviewHunk, GitReviewFile) -> Void

    var body: some View {
        VStack {
            if let file {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        fileHeader(file)
                        if file.isBinary {
                            ContentUnavailableView(
                                "Binary file",
                                systemImage: "doc.badge.ellipsis",
                                description: Text("Binary changes can be reviewed as a file, but not accepted or rejected by hunk."))
                        } else {
                            DiffPreview(diff: file.diff)
                            if !file.hunks.isEmpty {
                                hunkSection(file)
                            }
                        }
                    }
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "No changes to review",
                    systemImage: "checkmark.circle",
                    description: Text("The working copy matches the current commit."))
            }
        }
        .background(Theme.bg)
    }

    private func fileHeader(_ file: GitReviewFile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(file.path)
                    .font(.headline.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Text(file.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.info)
            }
            if file.isStaged {
                Label(
                    "Reject changes the working copy only; the staged snapshot is preserved.",
                    systemImage: "tray.full")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func hunkSection(_ file: GitReviewFile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Review by hunk")
                .font(.headline)
            ForEach(file.hunks) { hunk in
                GitReviewHunkCard(
                    hunk: hunk,
                    isAccepted: acceptedHunkIDs.contains(hunk.id),
                    isBusy: isBusy,
                    onAccept: { onAccept(hunk) },
                    onReject: { onReject(hunk, file) })
            }
        }
    }
}

private struct GitReviewHunkCard: View {
    let hunk: GitReviewHunk
    let isAccepted: Bool
    let isBusy: Bool
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Text(hunk.header)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                Text("+\(hunk.addedCount)")
                    .foregroundStyle(Theme.success)
                Text("−\(hunk.removedCount)")
                    .foregroundStyle(Theme.danger)
                Spacer()
                if isAccepted {
                    Label("Accepted", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.success)
                } else {
                    Button("Accept", action: onAccept)
                        .buttonStyle(LFCapsuleButtonStyle())
                    Button("Reject", role: .destructive, action: onReject)
                        .buttonStyle(LFCapsuleButtonStyle(tone: .destructive))
                        .disabled(isBusy)
                }
            }
            .padding(Spacing.sm)

            Divider().overlay(Theme.hairline)

            ScrollView(.horizontal) {
                Text(hunk.unified)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(Spacing.sm)
            }
        }
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(isAccepted ? Theme.success.opacity(0.45) : Theme.hairline, lineWidth: 1)
        }
    }
}
