import AppKit
import LoupeCore
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
            PullRequestHeader(pullRequest: pullRequest)
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
                if let page = showsFiles ? ConversationPage.existingPage(for: tab) : ConversationPage.page(for: tab) {
                    ConversationView(page: page, conversation: tab.conversation, error: tab.conversationError, isShown: !showsFiles)
                }
            }
        }
        // Showing the tab produces the diff if it isn't already in memory. Changes on GitHub
        // after that are offered by the banner rather than replacing what's being read.
        .task { await tab.load() }
        .background(WindowReader { ReviewWindows.shared.register(tab, for: $0) })
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
            FileBrowser(tab: tab, files: diff.files, hiddenCount: diff.hiddenCount)
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

/// Conversation and Files changed, as on github.com.
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
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var filesLabel: String {
        guard case let .ready(review) = tab.phase else { return "Files changed" }
        return "Files changed (\(review.files.count))"
    }
}

struct PullRequestHeader: View {
    let pullRequest: PullRequestSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(repositoryName(pullRequest)) #\(pullRequest.number)")
                        .font(.headline.monospacedDigit())
                    StateBadge(pullRequest: pullRequest, showsOpen: true)
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
                        ChecksIcon(state: checks)
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

/// The changed files beside the selected file's diff.
struct FileBrowser: View {
    @Bindable var tab: PullRequestTab
    let files: [FileDiff]
    let hiddenCount: Int
    /// Says so for a moment when the last file not viewed is marked viewed.
    @State private var showsAllViewed = false

    var body: some View {
        HSplitView {
            ReviewFileList(tab: tab, files: files, hiddenCount: hiddenCount)
                .frame(minWidth: 200, idealWidth: 300, maxWidth: 500)
            Group {
                if let file = files.first(where: { $0.id == tab.selectedFile }) {
                    DiffView(file: file, onAnchorClick: { anchor in print("clicked \(anchor)") }, review: review(of: file))
                } else {
                    Text(files.isEmpty ? "No changes to review" : "No file selected")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
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

    private func review(of file: FileDiff) -> FileReview {
        let isViewed = tab.viewedState(of: file.path).isViewed
        let label = if tab.nextUnviewedFile(after: file.id) != nil {
            isViewed ? "Next unreviewed file" : "Mark reviewed · next file"
        } else {
            isViewed ? "All files reviewed" : "Mark reviewed · last file"
        }
        return FileReview(
            isViewed: isViewed,
            toggleViewed: { Task { await tab.toggleViewed(path: file.path) } },
            advanceLabel: label,
            markViewedAndAdvance: { Task { await tab.markViewedAndAdvance() } }
        )
    }
}

/// The files to review, each with its viewed state, and a count of those hidden as vendored,
/// lockfiles or generated.
struct ReviewFileList: View {
    @Bindable var tab: PullRequestTab
    let files: [FileDiff]
    let hiddenCount: Int

    var body: some View {
        List(files, selection: $tab.selectedFile) { file in
            ReviewFileRow(file: file, state: tab.viewedState(of: file.path)) {
                Task { await tab.toggleViewed(path: file.path) }
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
                Text("\(viewedCount) of \(files.count) reviewed · \(hiddenCount) vendored, lockfile or generated hidden")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var viewedCount: Int {
        files.count { tab.viewedState(of: $0.path).isViewed }
    }
}

/// A file in the list: checked and dimmed once viewed, flagged when it has changed since, and
/// with a checkbox on hover to mark it either way.
struct ReviewFileRow: View {
    let file: FileDiff
    let state: FileViewedState
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if hovering {
                    Toggle("Reviewed", isOn: Binding(get: { state.isViewed }, set: { _ in toggle() }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help(state.isViewed ? "Mark not reviewed (⇧V)" : "Mark reviewed (⇧V)")
                } else if state.isViewed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.diffSuccess)
                }
            }
            .frame(width: 14)
            FileRow(file: file)
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
        .onHover { hovering = $0 }
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
