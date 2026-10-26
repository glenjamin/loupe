import LoupeInbox
import LoupeModel
import SwiftUI

/// What resting the pointer on an open PR's Conflicts badge, or the merge box's reason, shows:
/// which files conflict with its base. GitHub says only that something does, so they're found
/// locally, by merging the PR into its base as last fetched, the first time this is shown. A
/// file among the PR's changes shows in the diff when clicked.
struct ConflictsPopoverContent: HoverPopoverContent {
    let tab: PullRequestTab
    var onPointerOver: (Bool) -> Void = { _ in }
    var onOpen: () -> Void = {}

    var body: some View {
        let files = tab.conflictedFiles
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: title(files))
                        .font(.headline)
                    if files == nil || files == .finding {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let detail = detail(files) {
                    Text(verbatim: detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if files == .found([]) {
                    Button("Reload") {
                        onOpen()
                        Task { await tab.reload() }
                    }
                    .help("Fetch the PR and its base again, and look again")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if case let .found(paths)? = files, !paths.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(paths, id: \.self) { path in
                            ConflictedFileRow(path: path, tab: tab, onOpen: onOpen)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 380, alignment: .leading)
        .onHover(perform: onPointerOver)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conflicts-popover")
        .task { await tab.findConflicts() }
    }

    private func title(_ files: ConflictedFiles?) -> String {
        let base = tab.pullRequest.baseRefName
        switch files {
        case nil, .finding: return "Finding the conflicting files…"
        case .found([]): return "No conflicts with \(base) as last fetched"
        case let .found(paths): return paths.count == 1 ? "1 file conflicts with \(base)" : "\(paths.count) files conflict with \(base)"
        case .unavailable: return "Couldn't find the conflicting files"
        }
    }

    private func detail(_ files: ConflictedFiles?) -> String? {
        let base = tab.pullRequest.baseRefName
        switch files {
        case nil, .finding: return nil
        case .found([]): return "GitHub says this branch conflicts with \(base), but it merges cleanly into the \(base) Loupe last fetched. GitHub may have checked a newer one."
        case .found: return "Found by merging this branch into \(base) as last fetched, as GitHub would."
        case let .unavailable(reason): return reason
        }
    }
}

/// One conflicting file, which shows in the diff when clicked if the PR changes it. A file only
/// the base changed, as when it renamed one the PR edits, can't be shown, so says so.
private struct ConflictedFileRow: View {
    let path: String
    let tab: PullRequestTab
    let onOpen: () -> Void

    var body: some View {
        if tab.isChanged(path) {
            PopoverRowButton {
                onOpen()
                Task { await tab.showChangedFile(path) }
            } label: {
                label
            }
            .help("Show \(path) in the diff")
        } else {
            label
                .foregroundStyle(.secondary)
                .help("\(path) isn't among this PR's changes")
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.diffDanger)
                .frame(width: 14)
            Text(verbatim: path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
