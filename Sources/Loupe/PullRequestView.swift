import AppKit
import LoupeCore
import LoupeGit
import LoupeInbox
import LoupeModel
import SwiftUI

/// One PR's tab: its header, then a sidebar of the conversation, commit picker and files beside
/// whichever of them is chosen, the files once their diff is produced from the local checkout.
struct PullRequestView: View {
    @Bindable var tab: PullRequestTab
    let checkoutSearchRoots: [URL]

    var body: some View {
        let pullRequest = tab.pullRequest
        VStack(spacing: 0) {
            PullRequestHeader(pullRequest: pullRequest, tab: tab)
            Divider()
            if tab.pendingChange == .newCommits {
                NewCommitsBanner {
                    Task { await tab.reload() }
                } dismiss: {
                    tab.dismissPendingChange()
                }
                Divider()
            }
            HSplitView {
                ReviewSidebar(tab: tab)
                    .frame(minWidth: 200, idealWidth: 300, maxWidth: 500)
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
                        ConversationView(page: page, pullRequest: pullRequest, conversation: tab.conversation, error: tab.isFetchingConversation ? nil : tab.conversationError, isShown: !showsFiles && editor == nil)
                    }
                    if let editor {
                        DescriptionEditorView(editor: editor, tab: tab)
                    }
                }
                .frame(minWidth: 400)
            }
        }
        // Showing the tab produces the diff if it isn't already in memory. New commits after
        // that are offered by the banner rather than replacing what's being read.
        .task { await tab.load() }
    }

    @ViewBuilder
    private func content(_ pullRequest: PullRequestSummary) -> some View {
        switch tab.phase {
        case let .producing(step):
            // One view through every step, only its words changing, so it reads as one wait.
            LoadingLabel(title: step.title(of: pullRequest), detail: step.detail(of: pullRequest))
                .animation(.default, value: step)
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
        case let .ready(diff):
            FileDetail(tab: tab)
                // A new head can change a file under the same path.
                .id(diff.headOid)
                .dimmed(while: tab.isReplacingShownChanges)
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

/// The PR's navigation: its conversation at the top, then once the diff is ready the commit
/// picker and the files of the shown changes.
struct ReviewSidebar: View {
    @Bindable var tab: PullRequestTab

    var body: some View {
        VStack(spacing: 0) {
            ConversationRow(tab: tab)
            switch tab.phase {
            case let .ready(diff):
                CommitPicker(tab: tab, commits: diff.commits)
                Divider()
                ReviewFileList(tab: tab, changes: shownChanges, selection: fileSelection)
                    .id(diff.headOid)
                    .dimmed(while: tab.isReplacingShownChanges)
            case let .producing(step):
                // Where the commit picker will be, lined up with its label.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(step.sidebarTitle)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .animation(.default, value: step)
                Spacer(minLength: 0)
            case .noCheckout, .failed:
                Spacer(minLength: 0)
            }
        }
    }

    private var shownChanges: ReviewChanges? {
        if case let .ready(changes)? = tab.shownChanges { changes } else { nil }
    }

    /// No file reads as selected while the conversation is shown, and picking one shows the
    /// files; the selected file is kept meanwhile, so going back shows it again.
    private var fileSelection: Binding<FileDiff.ID?> {
        Binding {
            tab.section == .files ? tab.selectedFile : nil
        } set: { file in
            tab.selectedFile = file
            if file != nil { tab.section = .files }
        }
    }
}

/// The sidebar's first row, showing the conversation in place of the diff, highlighted as a
/// selected list row while it's shown. On the viewer's own PRs it then offers to edit the
/// description.
struct ConversationRow: View {
    @Bindable var tab: PullRequestTab

    var body: some View {
        let isShown = tab.section == .conversation
        HStack(spacing: 4) {
            Button { tab.section = .conversation } label: {
                Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the conversation (⌃1)")
            .accessibilityAddTraits(isShown ? .isSelected : [])
            .background(ConversationRowMarker())
            if isShown, tab.canEditDescription {
                Button("Edit description", systemImage: "pencil") {
                    Task { await tab.editDescription() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(tab.descriptionEditor != nil)
                .help("Edit this PR's description, starting from it as it is on GitHub now")
            }
        }
        .foregroundStyle(isShown ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isShown ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(8)
    }
}

/// Three sections on one row: the PR's name, state and branches; on the viewer's own PRs, while
/// it's open, a Merge button about 70% across, and on any merged or closed PR when that happened;
/// and their reviewers at the right, with any review of their own pending beneath them. On anyone
/// else's open PR the right holds the viewer's own review, and the middle their standing
/// approval or request for changes, if they've given one.
struct PullRequestHeader: View {
    let pullRequest: PullRequestSummary
    let tab: PullRequestTab

    var body: some View {
        HeaderLayout(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(repositoryName(pullRequest)) #\(pullRequest.number)")
                        .font(.headline.monospacedDigit())
                    StateBadge(pullRequest: pullRequest, showsOpen: true)
                    ConflictsBadge(pullRequest: pullRequest)
                    SelfReviewedBadge(isSelfReviewed: tab.isSelfReviewed)
                    Text(pullRequest.title)
                        .font(.title3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(pullRequest.title)
                }
                HStack(spacing: 10) {
                    if let author = pullRequest.author {
                        Label(author, systemImage: "person")
                    }
                    Text("\(pullRequest.headRefName) → \(pullRequest.baseRefName)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    OpenInEditorButton(pullRequest: pullRequest, tab: tab)
                    if let checks = pullRequest.checks {
                        ChecksIcon(state: checks, contexts: pullRequest.checkContexts)
                        FailedCheckNames(state: checks, contexts: pullRequest.checkContexts)
                    }
                    ReviewDecisionLabel(decision: pullRequest.reviewDecision, requestedReviewers: pullRequest.requestedReviewers)
                    HStack(spacing: 4) {
                        EveryMinute { now in
                            Text("updated \(pullRequest.updatedAt.ago(now: now))")
                        }
                        DelayedSpinner(isActive: tab.isCheckingGitHub)
                            .help("Checking GitHub for changes…")
                        if let error = tab.checkError {
                            BackgroundErrorLabel(error: error)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let line = tab.stackLine {
                    StackBar(line: line, tab: tab)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Each section is always there, empty when it has nothing, so the layout sees three.
            VStack(spacing: 2) {
                if let readiness = tab.mergeReadiness {
                    MergeBox(tab: tab, readiness: readiness)
                } else if let outcome = PullRequestOutcome(pullRequest) {
                    OutcomeLabel(outcome: outcome)
                } else if tab.canReview, let verdict = tab.viewerVerdict {
                    ViewerVerdictLabel(verdict: verdict)
                }
                if let error = tab.mergeError {
                    MergeErrorLabel(error: error)
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                if let reviewers = tab.reviewers {
                    ReviewersBlock(tab: tab, reviewers: reviewers)
                    // Under the reviewers rather than beside Merge, so neither moves.
                    if tab.canStartReview, tab.pendingReview != nil {
                        ReviewControls(tab: tab)
                    }
                } else if tab.canReview {
                    ReviewControls(tab: tab)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Checks the PR's branch out in its checkout and opens that in the repo's editor, with a
/// spinner while git works. Success shows nothing more, as the editor coming up says it; a
/// failure, or a branch not checked out quite as asked, says so in an alert.
struct OpenInEditorButton: View {
    let pullRequest: PullRequestSummary
    let tab: PullRequestTab

    var body: some View {
        let launch = tab.editorLaunch
        Button {
            Task { await tab.openInEditor { editor, directory in try await open(directory, in: editor) } }
        } label: {
            HStack(spacing: 3) {
                if launch.isSwitching {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "hammer")
                }
                Text(verbatim: "Open in \(tab.editor?.name ?? "Editor")")
            }
        }
        .buttonStyle(.borderless)
        .disabled(tab.editor == nil || launch.isSwitching)
        .help(help)
        .alert(
            launch.report?.title ?? "",
            isPresented: Binding(get: { launch.report != nil }, set: { if !$0 { launch.report = nil } }),
            presenting: launch.report
        ) { _ in
            Button("OK") {}
        } message: { report in
            Text(report.message)
        }
    }

    private var help: String {
        guard let checkout = tab.editorCheckout, let editor = tab.editor else {
            if case .noCheckout = tab.phase { return "There's no local checkout of \(pullRequest.repository) to open" }
            return "Available once the diff has found the local checkout"
        }
        if tab.editorLaunch.isSwitching { return "Checking out \(pullRequest.headRefName)…" }
        let path = (checkout.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        return "Check out \(pullRequest.headRefName) in \(path) and open it in \(editor.name)"
    }
}

/// The failed checks' names beside the header's checks glyph, cut short on one line; the
/// glyph's popover has the full list.
struct FailedCheckNames: View {
    let state: CheckState
    let contexts: [CheckContext]

    var body: some View {
        let names = contexts.failedCheckNames
        if state == .failure || state == .error, !names.isEmpty {
            Text(names.joined(separator: ", "))
                .foregroundStyle(.diffDanger)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
    }
}

/// Says new commits have been pushed since the diff was produced, without disturbing the diff,
/// and offers to reload it.
struct NewCommitsBanner: View {
    let reload: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Color.accentColor)
            Text("New commits pushed")
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

/// The selected file's diff, of the whole PR or one of its commits.
struct FileDetail: View {
    @Bindable var tab: PullRequestTab
    /// Says so for a moment when the last file not viewed is marked viewed.
    @State private var showsAllViewed = false

    var body: some View {
        detail
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
            LoadingLabel(title: "Diffing…")
        case let .failed(message):
            ContentUnavailableView {
                Label(failureTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await tab.show(tab.shownChoice) } }
            }
        case let .ready(changes):
            if let file = changes.files.first(where: { $0.id == tab.selectedFile }) {
                diffView(file)
            } else if let file = changes.hidden.first(where: { $0.id == tab.selectedFile }) {
                hiddenFile(file)
                    // Diffed only once shown, as a vendored file can be enormous.
                    .task(id: ShownFile(choice: tab.shownChoice, path: file.path)) { await tab.diffHiddenFile(file.path) }
                    .task(id: ShownFile(choice: tab.shownChoice, path: file.path)) { await tab.comparePackageLock(file.path) }
            } else {
                Text(changes.files.isEmpty && changes.hidden.isEmpty ? "No changes to review" : "No file selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// A hidden file's diff once made. Until then its diff last made, from other changes, stays
    /// dimmed in the same place, so switching commit doesn't blank it; with none, a spinner.
    @ViewBuilder
    private func hiddenFile(_ file: ChangedFile) -> some View {
        let state = tab.hiddenFileDiff(of: file.path)
        let ready: FileDiff? = if case let .ready(diff)? = state { diff } else { nil }
        if case let .failed(message)? = state {
            ContentUnavailableView {
                Label("Couldn't diff \(file.path)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            }
        } else if let diff = ready ?? tab.lastHiddenFileDiff(of: file.path) {
            diffView(diff)
                .dimmed(while: ready == nil)
        } else {
            LoadingLabel(title: "Diffing…", detail: file.path)
        }
    }

    private func diffView(_ file: FileDiff) -> some View {
        let shown = tab.expandedFile(file)
        return DiffView(
            file: shown, onAnchorClick: { anchor in print("clicked \(anchor)") }, isUnseparated: tab.unseparatedPaths.contains(file.path), review: review(of: file), markdown: tab.markdownPreview(of: file),
            packageLock: tab.packageLockPreview(of: file), image: tab.imagePreview(of: file),
            expandable: tab.expandableContext(of: file), onExpand: { expansion in Task { await tab.expandContext(of: file, expansion) } },
            onCollapse: tab.hasRevealedContext(of: file) ? { tab.collapseContext(of: file) } : nil,
            blocks: tab.threads(on: shown).map { threadBlocks(for: $0, onFileAt: file.path, in: tab) } ?? [],
            commentable: tab.commentableAnchors(of: shown), onComment: { anchor in tab.startComment(at: anchor) }
        )
        // Read when shown, so the lines after the last hunk can be offered as well.
        .task(id: ShownFile(choice: tab.shownChoice, path: file.path)) { await tab.readContext(of: file) }
    }

    private var failureTitle: String {
        if case .commit = tab.shownChoice { "Couldn't diff this commit" } else { "Couldn't diff these changes" }
    }

    private func review(of file: FileDiff) -> FileReview {
        let isViewed = tab.viewedState(of: file.path).isViewed
        let hasNext = tab.nextUnviewedFile(after: file.id) != nil
        // Only once the shown commit has no file left to review does moving on go to the next.
        let nextCommit = hasNext ? nil : tab.nextCommit
        let label = if hasNext {
            isViewed ? "Next unreviewed file" : "Mark reviewed · next file"
        } else if let nextCommit {
            isViewed ? "Next commit · \(shortened(nextCommit.headline))" : "Mark reviewed · next commit"
        } else if isViewed {
            switch tab.shownChoice {
            case .all: "All files reviewed"
            case .commit: "All this commit's files reviewed"
            case .since: "All these files reviewed"
            }
        } else {
            "Mark reviewed · last file"
        }
        let pullHint = switch (hasNext, isViewed) {
        case (true, false): "Pull to mark reviewed and move on"
        case (true, true): "Pull for the next unreviewed file"
        case (false, false): nextCommit == nil ? "Pull to mark the last file reviewed" : "Pull to mark reviewed and go to the next commit"
        case (false, true): nextCommit == nil ? label : "Pull for the next commit"
        }
        return FileReview(
            isViewed: isViewed,
            toggleViewed: { Task { await tab.toggleViewed(path: file.path) } },
            advanceLabel: label,
            pullHint: pullHint,
            markViewedAndAdvance: { Task { await tab.markViewedAndAdvance() } }
        )
    }

    /// A commit's headline cut short enough to sit in the footer's button.
    private func shortened(_ headline: String) -> String {
        let limit = 48
        return headline.count > limit ? headline.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" : headline
    }
}

/// Picks whether the files show the whole PR's changes or one commit's, as on github.com: a
/// button naming what's shown and how much it changes opens a list of the choices, each with its
/// whole first line and how much it changes. It's drawn as a sidebar row like Conversation's, but
/// never as selected, being a choice of what the files show rather than a place to go.
struct CommitPicker: View {
    @Bindable var tab: PullRequestTab
    let commits: [PullRequestCommit]
    @State private var isHovered = false

    var body: some View {
        Button { tab.isPickingCommit = true } label: {
            HStack(spacing: 4) {
                Label { shownLabel.lineLimit(1).truncationMode(.tail) } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                // Room for a commit's short oid at least, however narrow the sidebar.
                .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
                // Kept whole, truncating the name instead; when narrow, the line counts alone.
                if let stat = tab.diffStat(of: tab.pendingChoice ?? tab.shownChoice) {
                    ViewThatFits(in: .horizontal) {
                        DiffStatLabel(stat: stat).fixedSize()
                        LineCounts(additions: stat.additions, deletions: stat.deletions).fixedSize()
                    }
                    .layoutPriority(1)
                }
                DelayedSpinner(isActive: tab.isReplacingShownChanges)
                    .help(tab.reloading == nil ? "Diffing…" : "Reloading the diff…")
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the changes of the whole PR, of one commit, or since you last saw it")
        .background(CommitPickerMarker())
        .popover(isPresented: $tab.isPickingCommit, arrowEdge: .bottom) {
            CommitList(tab: tab, commits: commits)
        }
        // Counted as soon as the commits are shown, so the list opens complete; it's cheap.
        .task(id: commits.map(\.oid)) { await tab.countCommitChanges() }
        // Likewise each earlier head the viewer saw, fetched first if the checkout lacks it.
        .task(id: tab.anchors) { await tab.prepareAnchors() }
        .background(
            isHovered || tab.isPickingCommit ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .onHover { isHovered = $0 }
        // Sits right under the Conversation row, whose own padding spaces them.
        .padding([.horizontal, .bottom], 8)
    }

    /// Names the changes picked at once, even while they're still being diffed.
    private var shownLabel: Text {
        switch tab.pendingChoice ?? tab.shownChoice {
        case let .since(anchor):
            return Text(verbatim: anchorTitle(anchor))
        case let .commit(oid):
            if let commit = commits.first(where: { $0.oid == oid }) {
                return Text(verbatim: String(commit.oid.prefix(7))).monospaced() + Text(verbatim: "  \(commit.headline)")
            }
        case .all:
            break
        }
        return Text(verbatim: allCommitsTitle(commits.count))
    }
}

/// The choices of changes to show, each with its diff-stat, the shown one ticked: the whole PR's,
/// then those since the viewer last reviewed it or last opened it, and those of force-pushes
/// asked for from the conversation, then each commit's. A click picks one; the arrow keys move
/// between them and Return picks. Changes that turn out to be none, as after only a rebase, or
/// that can't be fetched, can't be picked, and say why when hovered.
struct CommitList: View {
    @Bindable var tab: PullRequestTab
    let commits: [PullRequestCommit]
    @State private var highlighted: ChangesChoice?
    @FocusState private var isFocused: Bool

    var body: some View {
        let anchors = tab.anchors
        List(selection: $highlighted) {
            row(.all, title: allCommitsTitle(commits.count), oid: nil)
            ForEach(anchors, id: \.self) { anchor in
                anchorRow(anchor)
            }
            Section("Commits") {
                ForEach(commits) { commit in
                    row(.commit(commit.oid), title: commit.headline, oid: commit.oid)
                }
            }
        }
        .contextMenu(forSelectionType: ChangesChoice.self) { _ in } primaryAction: { choices in
            if let choice = choices.first { pick(choice) }
        }
        .focused($isFocused)
        // Wide enough that most first lines fit whole; longer ones wrap.
        .frame(width: 480, height: min(CGFloat(commits.count + anchors.count + 1) * 60 + 50, 480))
        .onAppear {
            highlighted = shown
            isFocused = true
        }
    }

    /// The choice last picked, ticked even while it's still being diffed.
    private var shown: ChangesChoice {
        tab.pendingChoice ?? tab.shownChoice
    }

    private func row(_ choice: ChangesChoice, title: String, oid: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            tick(choice)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    stat(of: choice)
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

    /// The changes since an earlier head: named for how the viewer saw it, its stat, when they
    /// saw it and its short oid, which a force-push's names already have. Until they can be
    /// shown it's dimmed and can't be picked; when they can't be at all, the row says why in
    /// brief, and in full when hovered.
    private func anchorRow(_ anchor: ChangesAnchor) -> some View {
        let choice = ChangesChoice.since(anchor)
        let state = tab.anchorState(of: anchor)
        let isReady = state == .ready
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            tick(choice)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: anchorTitle(anchor))
                    .foregroundStyle(isReady ? .primary : .tertiary)
                HStack(spacing: 8) {
                    switch state {
                    case .ready:
                        stat(of: choice)
                    case .onlyRebased:
                        Label(anchor.kind == .forcePush ? "Only rebased, no changes" : "Only rebased since, no changes", systemImage: "info.circle")
                    case .failed:
                        Label("Couldn't fetch \(String(anchor.oid.prefix(7)))", systemImage: "exclamationmark.triangle")
                    case .checking, nil:
                        // Holds the row's height until it's looked at.
                        Text(verbatim: " ")
                    }
                    Spacer(minLength: 0)
                    if let at = anchor.at {
                        EveryMinute { now in
                            Text(verbatim: "\(anchorVerb(anchor.kind)) \(at.ago(now: now))")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if anchor.kind != .forcePush {
                        Text(verbatim: String(anchor.oid.prefix(7)))
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
        .background {
            if let help = HoverHelp(anchor: anchor, state: state) {
                HoverPopoverAnchor(content: help)
            }
        }
        .onTapGesture { pick(choice) }
        .tag(choice)
        .selectionDisabled(!isReady)
    }

    private func tick(_ choice: ChangesChoice) -> some View {
        Image(systemName: "checkmark")
            .font(.caption.bold())
            .opacity(choice == shown ? 1 : 0)
    }

    @ViewBuilder
    private func stat(of choice: ChangesChoice) -> some View {
        if let stat = tab.diffStat(of: choice) {
            DiffStatLabel(stat: stat)
        } else {
            // Holds the row's height until the changes are counted.
            Text(verbatim: " ")
        }
    }

    private func pick(_ choice: ChangesChoice) {
        if case let .since(anchor) = choice, tab.anchorState(of: anchor) != .ready { return }
        tab.isPickingCommit = false
        Task { await tab.show(choice) }
    }
}

/// A title and its explanation, in a popover as the checks' is, opened by resting the pointer on
/// what it explains.
struct HoverHelp: HoverPopoverContent {
    let title: String
    let detail: String
    var onPointerOver: (Bool) -> Void = { _ in }
    var onOpen: () -> Void = {}

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    /// Why the changes since an earlier head can't be shown. Nil when they can, or until that's
    /// known.
    init?(anchor: ChangesAnchor, state: AnchorState?) {
        let oid = String(anchor.oid.prefix(7))
        let since = switch anchor.kind {
        case .lastReview: "Only rebased since you last reviewed it, at \(oid)"
        case .lastOpened: "Only rebased since you last opened it, at \(oid)"
        case .forcePush: "Only rebased by this push"
        }
        switch state {
        case .onlyRebased:
            self.init(title: since, detail: "It was moved onto a newer base without any change of its own, so there's nothing new to review.")
        case let .failed(message):
            self.init(title: "Couldn't fetch \(oid) from the remote", detail: message)
        case .ready, .checking, nil:
            return nil
        }
    }

    /// Why a file's changes since an earlier head include its base's.
    static let unseparated = HoverHelp(
        title: "Couldn't separate from the rebase",
        detail: "The PR was rebased since, and this file's earlier changes don't apply cleanly to its new base, so this shows everything that changed in it since, its base's changes included."
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.headline)
            Text(verbatim: detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .onHover(perform: onPointerOver)
    }
}

/// The files to review as a tree of their directories, each file with its viewed state, then
/// those hidden as vendored, lockfiles or generated as a second tree, which can be shown and
/// marked reviewed too but are passed over when moving on.
struct ReviewFileList: View {
    @Bindable var tab: PullRequestTab
    /// Nil while being diffed.
    let changes: ReviewChanges?
    let selection: Binding<FileDiff.ID?>
    /// Directories folded shut, by tree; every one starts open.
    @State private var collapsed: [String: Set<String>] = [:]
    @FocusState private var isFocused: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        List(selection: selection) {
            if let changes {
                let files = Dictionary(changes.files.map { ($0.path, $0) }) { first, _ in first }
                Section {
                    FileTreeRows(tree: FileTree(paths: files.keys), collapsed: collapsed(in: "review")) { path in
                        if let file = files[path] {
                            row(path) { ReviewLineCounts(file: file) }
                        }
                    }
                }
                if !changes.hidden.isEmpty {
                    let hidden = Dictionary(changes.hidden.map { ($0.path, $0) }) { first, _ in first }
                    Section {
                        FileTreeRows(tree: FileTree(paths: hidden.keys), collapsed: collapsed(in: "hidden")) { path in
                            if let file = hidden[path] {
                                row(path, help: file.renamedFrom.map { "\($0) → \(file.path)" }) { HiddenFileChange(file: file) }
                            }
                        }
                    } header: {
                        Text(verbatim: "Vendored, lockfiles and generated (\(changes.hidden.count))")
                    }
                }
            }
        }
        .focused($isFocused)
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

    private func row(_ path: String, help: String? = nil, @ViewBuilder trailing: () -> some View) -> some View {
        ReviewFileRow(path: path, unresolvedThreads: tab.unresolvedThreadCount(of: path) ?? 0, state: tab.viewedState(of: path), isUnseparated: tab.unseparatedPaths.contains(path), trailing: trailing())
            // SwiftUI's List doesn't tell a row it's on the accent-coloured selection, so the
            // row is told here: selected, with the list focused in the key window.
            .environment(\.backgroundProminence, isEmphasized(path) ? .increased : .standard)
            .help(help ?? path)
            .tag(Optional(path))
    }

    private func isEmphasized(_ path: String) -> Bool {
        selection.wrappedValue == path && isFocused && activeState == .key
    }

    private func collapsed(in tree: String) -> Binding<Set<String>> {
        Binding { collapsed[tree] ?? [] } set: { collapsed[tree] = $0 }
    }
}

/// A tree's nodes as list rows, each stepped in by its depth: each directory a row that folds
/// it shut or opens it on a click, and each file the row `file` makes for its path. Directories
/// take no tag, so only files can be selected.
struct FileTreeRows<FileRow: View>: View {
    let tree: FileTree
    /// The paths of the directories folded shut.
    @Binding var collapsed: Set<String>
    @ViewBuilder let file: (String) -> FileRow

    var body: some View {
        ForEach(tree.rows(collapsed: collapsed)) { row in
            Group {
                switch row.node {
                case let .directory(directory):
                    directoryRow(directory)
                case let .file(path):
                    file(path)
                }
            }
            // About as far a level as github.com's tree steps in, to keep the sidebar's width for names.
            .padding(.leading, CGFloat(row.depth) * 12)
        }
    }

    private func directoryRow(_ directory: FileTree.Directory) -> some View {
        let isCollapsed = collapsed.contains(directory.path)
        return Button {
            if isCollapsed { collapsed.remove(directory.path) } else { collapsed.insert(directory.path) }
        } label: {
            HStack(spacing: 6) {
                // As wide as a file row's leading space, so a directory's symbol lines up with
                // its siblings'.
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(verbatim: directory.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The ForEach tags every row with its id, so without this the list would select a
        // directory, which has nothing to show.
        .selectionDisabled()
        .background(DirectoryRowMarker())
        .help(directory.path)
    }
}

/// A file in the list on one line: its name and open conversations, dimmed once viewed, flagged
/// when it has changed since being viewed, then a tick once viewed and `trailing` at the end.
/// The tick's slot is kept when there's no tick, so marking a file doesn't shift its row.
/// Selected in a key window, it all takes the selection's foreground, undimmed, as Finder's
/// sidebar does, since colours and fading don't read on the accent background.
struct ReviewFileRow<Trailing: View>: View {
    let path: String
    let unresolvedThreads: Int
    let state: FileViewedState
    /// Whether its changes since a rebase couldn't be told apart from the rebase's.
    var isUnseparated = false
    let trailing: Trailing
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 6) {
            // As wide as a directory's chevron, so a file's symbol lines up with its sibling
            // folders' and sits right of its parent's.
            Color.clear.frame(width: 14, height: 14)
            HStack(spacing: 6) {
                FileName(path: path)
                UnresolvedThreadCount(count: unresolvedThreads)
            }
            .opacity(dimming)
            if state == .dismissed {
                Text("changed")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(.secondary)
                    .overlay(Capsule().strokeBorder(.secondary.opacity(0.5)))
                    .help("Changed since you reviewed it")
                    .fixedSize()
            }
            if isUnseparated {
                UnseparatedBadge(label: "rebase")
            }
            Spacer(minLength: 4)
            // A clear view holds the slot, as an empty one takes no room in a stack.
            Color.clear
                .frame(width: 14, height: 14)
                .overlay {
                    if state.isViewed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(prominence.rowStyle(.diffSuccess))
                    }
                }
            trailing
                .fixedSize()
                .opacity(dimming)
        }
    }

    private var dimming: Double {
        state.isViewed && prominence != .increased ? 0.5 : 1
    }
}

/// Marks a file whose changes since a rebase couldn't be told apart from the rebase's, so its
/// diff includes its base's changes, explained when hovered.
struct UnseparatedBadge: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(.secondary)
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.5)))
            .fixedSize()
            .background(HoverPopoverAnchor(content: HoverHelp.unseparated))
    }
}

/// A file to review's line counts, or for one with no lines counted, what happened to it.
struct ReviewLineCounts: View {
    let file: FileDiff

    var body: some View {
        if file.additions == 0 && file.deletions == 0 {
            Text(file.isBinary ? "binary" : file.change.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            LineCounts(additions: file.additions, deletions: file.deletions)
        }
    }
}

/// What happened to a hidden file where that says more than its counts, then its counts, or
/// that it's binary.
struct HiddenFileChange: View {
    let file: ChangedFile

    var body: some View {
        HStack(spacing: 6) {
            if file.change != .modified {
                Text(file.change.summary).foregroundStyle(.secondary)
            }
            if file.isBinary {
                Text("binary").foregroundStyle(.secondary)
            } else {
                LineCounts(additions: file.additions, deletions: file.deletions)
            }
        }
        .font(.caption)
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
            .fixedSize()
            .help(count == 1 ? "1 unresolved conversation" : "\(count) unresolved conversations")
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

/// Which file is shown of which changes, for work done once per file shown.
private struct ShownFile: Equatable {
    let choice: ChangesChoice
    let path: String
}

/// `3 files  +42 −7`, as github.com counts them, with no thousands separators: the lines coloured
/// as in the file rows, so the size of a change reads at a glance, and the file count secondary.
private struct DiffStatLabel: View {
    let stat: DiffStat

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(stat.files) \(stat.files == 1 ? "file" : "files")")
                .foregroundStyle(.secondary)
            LineCounts(additions: stat.additions, deletions: stat.deletions)
        }
        .font(.caption.monospacedDigit())
    }
}

/// An empty view behind the commit picker's button, so a snapshot run can find where it is.
struct CommitPickerMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

/// An empty view behind the Conversation row, so a snapshot run can find where it is.
struct ConversationRowMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

/// Marks a directory row in the file tree, so a snapshot run can find it to click.
struct DirectoryRowMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

/// The header's info, merge and reviews sections, top-aligned on one row. The merge section is
/// centred about 70% across whatever else is there, moving left only to clear the reviewers,
/// and the info section is given what's left before it, so a long title truncates instead.
private struct HeaderLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + 2 * spacing
        let height = frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 3 else { return subviews.map { _ in .zero } }
        let (info, merge, reviews) = (subviews[0], subviews[1], subviews[2])
        let reviewsSize = reviews.sizeThatFits(.unspecified)
        let reviewsX = width - reviewsSize.width
        // The space left of the reviewers, less a gap when they're there.
        let end = reviewsSize.width > 0 ? reviewsX - spacing : width
        let centre = width * Self.mergeCentre
        let mergeSize = merge.sizeThatFits(ProposedViewSize(width: max(0, min(Self.mergeMaxWidth, 2 * (end - centre))), height: nil))
        let mergeX = min(centre - mergeSize.width / 2, end - mergeSize.width)
        let infoWidth = max(0, mergeSize.width > 0 ? mergeX - spacing : end)
        let infoSize = info.sizeThatFits(ProposedViewSize(width: infoWidth, height: nil))
        return [
            CGRect(x: 0, y: 0, width: infoWidth, height: infoSize.height),
            CGRect(origin: CGPoint(x: mergeX, y: 0), size: mergeSize),
            CGRect(origin: CGPoint(x: reviewsX, y: 0), size: reviewsSize),
        ]
    }

    private static let mergeCentre: CGFloat = 0.7
    /// How wide a refused merge's message may grow before it wraps.
    private static let mergeMaxWidth: CGFloat = 240
}

/// Names the whole PR's changes by how many commits the picker can step through; before the
/// commits are listed there's no count to give.
private func allCommitsTitle(_ count: Int) -> String {
    switch count {
    case 0: "All commits"
    case 1: "All 1 commit"
    default: "All \(count) commits"
    }
}

/// How the changes since an earlier head are named in the picker.
private func anchorTitle(_ anchor: ChangesAnchor) -> String {
    switch anchor.kind {
    case .lastReview: "Since your last review"
    case .lastOpened: "Since you last opened it"
    case .forcePush: "Force-push \(anchor.oid.prefix(7)) → \(anchor.head?.prefix(7) ?? "head")"
    }
}

/// What happened when the earlier head was seen or replaced, before when it did.
private func anchorVerb(_ kind: ChangesAnchor.Kind) -> String {
    switch kind {
    case .lastReview: "reviewed"
    case .lastOpened: "opened"
    case .forcePush: "pushed"
    }
}

/// A wait for git, centred in the space it will fill: a small spinner over what's happening in
/// secondary text, and what it's happening to below that.
struct LoadingLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: title)
                .foregroundStyle(.secondary)
            if let detail {
                Text(verbatim: detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small spinner shown only once work has gone on a moment, so quick work doesn't flicker it.
struct DelayedSpinner: View {
    let isActive: Bool
    @State private var isShown = false

    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .opacity(isActive && isShown ? 1 : 0)
            .frame(width: isActive ? nil : 0)
            .task(id: isActive) { isShown = await settled(isActive) }
    }
}

/// Says quietly that a check made in the background failed, so stale content isn't taken as
/// current; the full error is in the tooltip.
struct BackgroundErrorLabel: View {
    let error: String

    var body: some View {
        Label("Couldn't check for changes: \(error)", systemImage: "exclamationmark.triangle")
            .truncationMode(.tail)
            .layoutPriority(-1)
            .help(error)
    }
}

extension View {
    /// Dims content that's about to be replaced and stops it taking clicks, until it is. The
    /// dimming waits a moment, so quick work doesn't flicker it.
    func dimmed(while isReplaced: Bool) -> some View {
        modifier(DimmedWhileReplaced(isReplaced: isReplaced))
    }
}

private struct DimmedWhileReplaced: ViewModifier {
    let isReplaced: Bool
    @State private var isDimmed = false

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!isReplaced)
            // A veil rather than opacity, which AppKit-backed lists apply layer by layer, so
            // rows would show through their own footer. Lifted at once when replaced, so the
            // new content never shows dimmed.
            .overlay {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(isReplaced && isDimmed ? 0.5 : 0)
                    .animation(isReplaced && isDimmed ? .easeInOut(duration: 0.15) : nil, value: isReplaced && isDimmed)
                    .allowsHitTesting(isReplaced)
            }
            .task(id: isReplaced) { isDimmed = await settled(isReplaced) }
    }
}

/// `isActive` once it has stayed so for a moment, or false at once.
@MainActor
private func settled(_ isActive: Bool) async -> Bool {
    guard isActive else { return false }
    return (try? await Task.sleep(for: .milliseconds(150))) != nil
}

private extension DiffStep {
    /// What the step is doing, said in the detail pane.
    func title(of pullRequest: PullRequestSummary) -> String {
        switch self {
        case .resolvingCheckout: "Finding the local checkout…"
        case .fetching: "Fetching #\(pullRequest.number) from origin…"
        case .diffing: "Diffing…"
        }
    }

    /// What the step works on, under its title.
    func detail(of pullRequest: PullRequestSummary) -> String {
        switch self {
        case .resolvingCheckout: pullRequest.repository
        case .fetching: "\(pullRequest.repository) · \(pullRequest.headRefName)"
        case .diffing: "\(pullRequest.headRefName) → \(pullRequest.baseRefName)"
        }
    }

    /// The step said briefly, for the sidebar.
    var sidebarTitle: String {
        switch self {
        case .resolvingCheckout: "Finding the local checkout…"
        case .fetching: "Fetching from origin…"
        case .diffing: "Diffing…"
        }
    }
}
