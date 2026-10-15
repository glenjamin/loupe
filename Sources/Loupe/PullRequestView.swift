import AppKit
import LoupeCore
import LoupeGit
import LoupeInbox
import LoupeModel
import SwiftUI

/// One PR's tab: its header, then GitHub-style tabs for its conversation and for its diff, once
/// produced from the local checkout.
struct PullRequestView: View {
    @Bindable var tab: PullRequestTab
    let checkoutSearchRoots: [URL]

    var body: some View {
        let pullRequest = tab.pullRequest
        VStack(spacing: 0) {
            PullRequestHeader(pullRequest: pullRequest, tab: tab)
            ReviewSectionPicker(tab: tab)
            Divider()
            if let change = tab.pendingChange {
                PendingChangeBanner(change: change) {
                    Task { await tab.reload() }
                } dismiss: {
                    tab.dismissPendingChange()
                }
                Divider()
            }
            // Both stay once made, so switching keeps each one's place.
            ZStack {
                let showsFiles = tab.section == .files
                content(pullRequest)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showsFiles ? 1 : 0)
                    .allowsHitTesting(showsFiles)
                    .accessibilityHidden(!showsFiles)
                // The description's editor takes the conversation's place while open; the web
                // view stays behind it, keeping its place.
                let editor = showsFiles ? nil : tab.descriptionEditor
                if let page = showsFiles ? ConversationPage.existingPage(for: tab) : ConversationPage.page(for: tab) {
                    ConversationView(page: page, conversation: tab.conversation, error: tab.conversationError, isShown: !showsFiles && editor == nil)
                }
                if let editor {
                    DescriptionEditorView(editor: editor, tab: tab)
                }
            }
        }
        // Showing the tab produces the diff if it isn't already in memory. Changes on GitHub
        // after that are offered by the banner rather than replacing what's being read.
        .task { await tab.load() }
    }

    @ViewBuilder
    private func content(_ pullRequest: PullRequestSummary) -> some View {
        switch tab.phase {
        case .resolvingCheckout:
            ProgressView("Finding the local checkout…")
        case .noCheckout:
            ContentUnavailableView {
                Label("No local checkout of \(pullRequest.repository)", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Diffs come from a local checkout. None was found named \(repositoryName(pullRequest)) under \(checkoutSearchRoots.map { $0.path(percentEncoded: false) }.formatted()).")
            } actions: {
                Button("Locate Checkout…") {
                    locateCheckout(of: pullRequest.repository, startingAt: checkoutSearchRoots.first) { directory in
                        try await tab.locateCheckout(at: directory)
                    }
                }
            }
        case .fetching:
            ProgressView { Text(verbatim: "Fetching #\(pullRequest.number) from origin…") }
        case .diffing:
            ProgressView("Diffing…")
        case let .ready(diff):
            FileBrowser(tab: tab, commits: diff.commits)
                // A new head can change a file under the same path.
                .id(diff.headOid)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't produce the diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await tab.retry() } }
            }
        }
    }
}

/// Conversation and Files changed, as on github.com, and on the viewer's own PRs a button to
/// edit the description while the conversation is shown.
struct ReviewSectionPicker: View {
    @Bindable var tab: PullRequestTab

    var body: some View {
        HStack {
            Picker("Show", selection: $tab.section) {
                Text("Conversation").tag(ReviewSection.conversation)
                Text(filesLabel).tag(ReviewSection.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("⌃1 Conversation, ⌃2 Files changed")
            Spacer(minLength: 0)
            if tab.section == .conversation, tab.canEditDescription {
                Button("Edit description", systemImage: "pencil") {
                    Task { await tab.editDescription() }
                }
                .disabled(tab.descriptionEditor != nil)
                .help("Edit this PR's description, starting from it as it is on GitHub now")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var filesLabel: String {
        guard case let .ready(review) = tab.phase else { return "Files changed" }
        return "Files changed (\(review.changes.files.count))"
    }
}

/// The PR's name, state and branches, and on the right, on the viewer's own PRs, its reviewers.
/// On anyone else's that place is left for the viewer's own review.
struct PullRequestHeader: View {
    let pullRequest: PullRequestSummary
    let tab: PullRequestTab

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(repositoryName(pullRequest)) #\(pullRequest.number)")
                        .font(.headline.monospacedDigit())
                    StateBadge(pullRequest: pullRequest, showsOpen: true)
                    ConflictsBadge(pullRequest: pullRequest)
                    SelfReviewedBadge(isSelfReviewed: tab.isSelfReviewed)
                    Text(pullRequest.title)
                        .font(.title3)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    if let author = pullRequest.author {
                        Label(author, systemImage: "person")
                    }
                    Text("\(pullRequest.headRefName) → \(pullRequest.baseRefName)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    if let checks = pullRequest.checks {
                        ChecksIcon(state: checks, contexts: pullRequest.checkContexts)
                    }
                    if let decision = pullRequest.reviewDecision {
                        ReviewDecisionLabel(decision: decision)
                    }
                    TimelineView(.everyMinute) { _ in
                        Text("updated \(pullRequest.updatedAt.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let reviewers = tab.reviewers {
                ReviewersBlock(tab: tab, reviewers: reviewers)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Says the PR has changed on GitHub since its diff was produced, without disturbing the diff,
/// and offers to reload it.
struct PendingChangeBanner: View {
    let change: PendingChange
    let reload: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: change == .newCommits ? "arrow.triangle.branch" : "bell")
                .foregroundStyle(Color.accentColor)
            Text(change == .newCommits ? "New commits pushed" : "Updated on GitHub")
            Spacer(minLength: 0)
            Button("Reload", action: reload)
                .controlSize(.small)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
    }
}

/// The changed files, of the whole PR or one of its commits, beside the selected file's diff.
struct FileBrowser: View {
    @Bindable var tab: PullRequestTab
    let commits: [PullRequestCommit]
    /// Says so for a moment when the last file not viewed is marked viewed.
    @State private var showsAllViewed = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                CommitPicker(tab: tab, commits: commits)
                Divider()
                ReviewFileList(tab: tab, changes: shownChanges)
            }
            .frame(minWidth: 200, idealWidth: 300, maxWidth: 500)
            detail
                .frame(minWidth: 400)
                .overlay(alignment: .bottom) {
                    if showsAllViewed {
                        Label("All files reviewed", systemImage: "checkmark.circle.fill")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 24)
                            .transition(.opacity)
                    }
                }
        }
        .onChange(of: tab.allFilesViewed) { _, allViewed in
            withAnimation { showsAllViewed = allViewed }
        }
        .task(id: showsAllViewed) {
            guard showsAllViewed, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            withAnimation { showsAllViewed = false }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch tab.shownChanges {
        case .diffing, nil:
            ProgressView("Diffing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't diff this commit", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await tab.showCommit(tab.shownCommit) } }
            }
        case let .ready(changes):
            if let file = changes.files.first(where: { $0.id == tab.selectedFile }) {
                diffView(file)
            } else if let file = changes.hidden.first(where: { $0.id == tab.selectedFile }) {
                hiddenFile(file)
                    // Diffed only once shown, as a vendored file can be enormous.
                    .task(id: "\(tab.shownCommit ?? "")\0\(file.path)") { await tab.diffHiddenFile(file.path) }
            } else {
                Text(changes.files.isEmpty && changes.hidden.isEmpty ? "No changes to review" : "No file selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func hiddenFile(_ file: ChangedFile) -> some View {
        switch tab.hiddenFileDiff(of: file.path) {
        case .diffing, nil:
            ProgressView("Diffing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .ready(diff):
            diffView(diff)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't diff \(file.path)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            }
        }
    }

    private func diffView(_ file: FileDiff) -> some View {
        let shown = tab.expandedFile(file)
        return DiffView(
            file: shown, onAnchorClick: { anchor in print("clicked \(anchor)") }, review: review(of: file), markdown: tab.markdownPreview(of: file),
            expandable: tab.expandableContext(of: file), onExpand: { expansion in Task { await tab.expandContext(of: file, expansion) } },
            blocks: tab.threads(on: shown).map { threadBlocks(for: $0, in: tab) } ?? []
        )
        // Read when shown, so the lines after the last hunk can be offered as well.
        .task(id: "\(tab.shownCommit ?? "")\0\(file.path)") { await tab.readContext(of: file) }
    }

    private var shownChanges: ReviewChanges? {
        if case let .ready(changes)? = tab.shownChanges { changes } else { nil }
    }

    private func review(of file: FileDiff) -> FileReview {
        let isViewed = tab.viewedState(of: file.path).isViewed
        let hasNext = tab.nextUnviewedFile(after: file.id) != nil
        let label = if hasNext {
            isViewed ? "Next unreviewed file" : "Mark reviewed · next file"
        } else if isViewed {
            tab.shownCommit == nil ? "All files reviewed" : "All this commit's files reviewed"
        } else {
            "Mark reviewed · last file"
        }
        let pullHint = switch (hasNext, isViewed) {
        case (true, false): "Pull to mark reviewed and move on"
        case (true, true): "Pull for the next unreviewed file"
        case (false, false): "Pull to mark the last file reviewed"
        case (false, true): label
        }
        return FileReview(
            isViewed: isViewed,
            toggleViewed: { Task { await tab.toggleViewed(path: file.path) } },
            advanceLabel: label,
            pullHint: pullHint,
            markViewedAndAdvance: { Task { await tab.markViewedAndAdvance() } }
        )
    }
}

/// Picks whether the files show the whole PR's changes or one commit's, as on github.com: a
/// button naming what's shown opens a list of the choices, each with its whole first line and
/// how much it changes.
struct CommitPicker: View {
    @Bindable var tab: PullRequestTab
    let commits: [PullRequestCommit]

    var body: some View {
        Button { tab.isPickingCommit = true } label: {
            HStack(spacing: 6) {
                shownLabel
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .help("Show the changes of the whole PR or of one commit")
        .background(CommitPickerMarker())
        .popover(isPresented: $tab.isPickingCommit, arrowEdge: .bottom) {
            CommitList(tab: tab, commits: commits)
        }
        // Counted as soon as the commits are shown, so the list opens complete; it's cheap.
        .task(id: commits.map(\.oid)) { await tab.countCommitChanges() }
        .padding(8)
    }

    private var shownLabel: Text {
        guard let commit = commits.first(where: { $0.oid == tab.shownCommit }) else { return Text("All changes") }
        return Text(verbatim: String(commit.oid.prefix(7))).monospaced() + Text(verbatim: "  \(commit.headline)")
    }
}

/// The choices of changes to show, each with its diff-stat, the shown one ticked. A click picks
/// one; the arrow keys move between them and Return picks.
struct CommitList: View {
    @Bindable var tab: PullRequestTab
    let commits: [PullRequestCommit]
    @State private var highlighted: CommitChoice?
    @FocusState private var isFocused: Bool

    var body: some View {
        List(selection: $highlighted) {
            row(.all, title: "All changes", oid: nil)
            Section("Commits") {
                ForEach(commits) { commit in
                    row(.commit(commit.oid), title: commit.headline, oid: commit.oid)
                }
            }
        }
        .contextMenu(forSelectionType: CommitChoice.self) { _ in } primaryAction: { choices in
            if let choice = choices.first { pick(choice) }
        }
        .focused($isFocused)
        // Wide enough that most first lines fit whole; longer ones wrap.
        .frame(width: 480, height: min(CGFloat(commits.count + 1) * 60 + 50, 480))
        .onAppear {
            highlighted = shown
            isFocused = true
        }
    }

    private var shown: CommitChoice {
        tab.shownCommit.map(CommitChoice.commit) ?? .all
    }

    private func row(_ choice: CommitChoice, title: String, oid: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption.bold())
                .opacity(choice == shown ? 1 : 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(verbatim: tab.diffStat(ofCommit: oid).map(describe) ?? " ")
                    Spacer(minLength: 0)
                    if let oid {
                        Text(verbatim: String(oid.prefix(7)))
                            .monospaced()
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { pick(choice) }
        .tag(choice)
    }

    private func pick(_ choice: CommitChoice) {
        tab.isPickingCommit = false
        let oid: String? = switch choice {
        case .all: nil
        case let .commit(oid): oid
        }
        Task { await tab.showCommit(oid) }
    }
}

/// The files to review, each with its viewed state, then those hidden as vendored, lockfiles or
/// generated, which can be shown and marked reviewed too but are passed over when moving on.
struct ReviewFileList: View {
    @Bindable var tab: PullRequestTab
    /// Nil while being diffed.
    let changes: ReviewChanges?

    var body: some View {
        List(selection: $tab.selectedFile) {
            if let changes {
                Section {
                    ForEach(changes.files) { file in
                        row(file.path) { FileRow(file: file, unresolvedThreads: tab.unresolvedThreadCount(of: file.path) ?? 0) }
                    }
                }
                if !changes.hidden.isEmpty {
                    Section {
                        ForEach(changes.hidden) { file in
                            row(file.path) { HiddenFileRow(file: file, unresolvedThreads: tab.unresolvedThreadCount(of: file.path) ?? 0) }
                        }
                    } header: {
                        Text(verbatim: "Vendored, lockfiles and generated (\(changes.hidden.count))")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let error = tab.viewedStateError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.diffDanger)
                        .lineLimit(2)
                        .help(error)
                }
                if let changes {
                    Text(verbatim: "\(changes.files.count { tab.viewedState(of: $0.path).isViewed }) of \(changes.files.count) reviewed")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            // So rows scrolled under it don't show through.
            .background(.bar)
        }
    }

    private func row(_ path: String, @ViewBuilder content: () -> some View) -> some View {
        ReviewFileRow(row: content(), state: tab.viewedState(of: path))
            .tag(Optional(path))
    }
}

/// A hidden file's name over its line counts, what happened to it where that says more than
/// the counts, and its directory, as for the files to review.
struct HiddenFileRow: View {
    let file: ChangedFile
    var unresolvedThreads = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: (file.path as NSString).lastPathComponent).lineLimit(1)
                UnresolvedThreadCount(count: unresolvedThreads)
            }
            HStack(spacing: 6) {
                if file.isBinary {
                    Text("binary").foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "+\(file.additions)").foregroundStyle(.diffSuccess)
                    Text(verbatim: "-\(file.deletions)").foregroundStyle(.diffDanger)
                }
                if let change {
                    Text(change).foregroundStyle(.secondary)
                }
                Text(verbatim: (file.path as NSString).deletingLastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(.caption.monospacedDigit())
        }
        .help(file.renamedFrom.map { "\($0) → \(file.path)" } ?? file.path)
    }

    /// Nil for a modification, which the counts already say.
    private var change: String? {
        switch file.change {
        case .added: "added"
        case .deleted: "deleted"
        case .modified: nil
        case .renamed: "renamed"
        case .copied: "copied"
        }
    }
}

/// How many conversations on a file are still open, beside its name; nothing when none are.
struct UnresolvedThreadCount: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left")
                Text(verbatim: "\(count)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help(count == 1 ? "1 unresolved conversation" : "\(count) unresolved conversations")
        }
    }
}

/// A file in the list: ticked and dimmed once viewed, and flagged when it has changed since.
/// The tick's slot is kept when there's no tick, so names line up down the list.
struct ReviewFileRow<Row: View>: View {
    let row: Row
    let state: FileViewedState

    var body: some View {
        HStack(spacing: 6) {
            // A clear view holds the slot, as an empty one takes no room in a stack.
            Color.clear
                .frame(width: 14, height: 14)
                .overlay {
                    if state.isViewed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.diffSuccess)
                    }
                }
            row
                .opacity(state.isViewed ? 0.5 : 1)
            if state == .dismissed {
                Spacer(minLength: 0)
                Text("changed")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(.secondary)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5)))
                    .help("Changed since you reviewed it")
            }
        }
    }
}

/// Asks for the repo's checkout directory and hands it to `locate`, saying so if it's rejected.
@MainActor
func locateCheckout(of repository: String, startingAt directory: URL?, locate: @escaping @MainActor (URL) async throws -> Void) {
    let panel = NSOpenPanel()
    panel.message = "Choose the local checkout of \(repository)"
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = directory
    guard panel.runModal() == .OK, let chosen = panel.url else { return }
    Task {
        do {
            try await locate(chosen)
        } catch {
            let alert = NSAlert()
            alert.messageText = "That isn't a checkout of \(repository)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// The repo's name without its owner.
func repositoryName(_ pullRequest: PullRequestSummary) -> String {
    pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository
}

/// One of the changes a `CommitList` offers, as a list needs a selection that isn't nil.
private enum CommitChoice: Hashable {
    case all
    case commit(String)
}

/// `3 files  +42 −7`, as github.com counts them, with no thousands separators.
private func describe(_ stat: DiffStat) -> String {
    "\(stat.files) \(stat.files == 1 ? "file" : "files")  +\(stat.additions) \u{2212}\(stat.deletions)"
}

/// An empty view behind the commit picker's button, so a snapshot run can find where it is.
struct CommitPickerMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}
