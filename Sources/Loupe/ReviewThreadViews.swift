import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
import SwiftUI

/// The blocks a file's diff lays over its rows for its review threads: one under each line
/// threads end on, one after the last row for those with nowhere in the diff to go, and the
/// comment being started on one of the file's lines, if any.
@MainActor
func threadBlocks(for threads: FileThreads, onFileAt path: String, in tab: PullRequestTab) -> [DiffBlockContent] {
    let activity = tab.threadActivity
    // The block with the thread the conversation asked to show scrolls into view once.
    func reveal(_ shown: [ReviewThread]) -> (() -> Void)? {
        guard let id = activity.revealing, shown.contains(where: { $0.id == id }) else { return nil }
        return { activity.didReveal(id) }
    }
    var blocks = threads.anchored.map { line in
        DiffBlockContent(
            id: "threads:\(line.side.rawValue):\(line.line)",
            placement: .after(side: line.side, line: line.line),
            view: AnyView(ThreadStack(tab: tab, threads: line.threads)),
            reveal: reveal(line.threads)
        )
    }
    if !threads.elsewhere.isEmpty {
        blocks.append(DiffBlockContent(
            id: "threads:elsewhere", placement: .end, view: AnyView(ElsewhereThreads(tab: tab, threads: threads.elsewhere)), reveal: reveal(threads.elsewhere)
        ))
    }
    // A comment being started goes under its line, after any threads already there.
    if let comment = tab.threadActivity.newComment, comment.anchor.path == path {
        let anchor = comment.anchor
        blocks.append(DiffBlockContent(
            id: "new-comment:\(anchor.side.rawValue):\(anchor.line)",
            placement: .after(side: anchor.side, line: anchor.line),
            view: AnyView(NewCommentCard(tab: tab, comment: comment))
        ))
    }
    return blocks
}

/// A comment being started on a line, which posts as a new thread.
private struct NewCommentCard: View {
    let tab: PullRequestTab
    let comment: NewComment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "Comment on line \(comment.anchor.line)\(comment.anchor.side == .left ? " (old)" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let error = tab.threadActivity.newCommentError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.diffDanger)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(error)
                }
                CommentComposer(tab: tab, draft: comment.draft, caption: caption, actions: actions, cancel: { tab.cancelComment() })
            }
            .font(.callout)
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .modifier(BlockInset())
    }

    /// Where the viewer can start a review, their own PR included, a single comment posted at
    /// once and one into their review, as on github.com; ⌘↩ adds to a pending review, and
    /// otherwise posts at once, and ⌘⇧↩ does the other.
    private var actions: [ComposerAction] {
        let atOnce = "Post this comment at once, not as part of a review"
        guard tab.canStartReview else {
            return [ComposerAction(label: "Comment", help: atOnce) { Task { await tab.sendComment() } }]
        }
        let single = ComposerAction(label: "Add single comment", help: atOnce) { Task { await tab.sendComment() } }
        guard tab.pendingReview != nil else {
            let start = ComposerAction(label: "Start a review", help: "Start a review with this comment; no one else sees it until the review is submitted") {
                Task { await tab.sendReviewComment() }
            }
            return [single, start]
        }
        let add = ComposerAction(label: "Add review comment", help: "Add this comment to your pending review; no one else sees it until the review is submitted") {
            Task { await tab.sendReviewComment() }
        }
        return [add, single]
    }

    private var caption: String {
        guard tab.canStartReview else { return "Markdown. Posts at once, not as part of a review." }
        return tab.pendingReview == nil
            ? "Markdown. ⌘↩ posts a single comment; ⌘⇧↩ starts a review."
            : "Markdown. ⌘↩ adds to your review; ⌘⇧↩ posts a single comment."
    }
}

/// The threads ending on one line, one card each, indented to sit under the code.
private struct ThreadStack: View {
    let tab: PullRequestTab
    let threads: [ReviewThread]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(threads) { thread in
                ThreadCard(tab: tab, thread: thread, showsHunk: false)
            }
        }
        .modifier(BlockInset())
    }
}

/// Threads the diff has no line for: outdated ones, ones on the whole file, and ones on lines
/// it doesn't show. Each shows the snippet of diff it was made on, so nothing is lost.
private struct ElsewhereThreads: View {
    let tab: PullRequestTab
    let threads: [ReviewThread]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not on the current diff")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(threads) { thread in
                ThreadCard(tab: tab, thread: thread, showsHunk: !thread.diffHunk.isEmpty)
            }
        }
        .modifier(BlockInset())
    }
}

/// A review thread: its comments in order under a header naming its lines. A resolved one is
/// a single quiet line until opened.
private struct ThreadCard: View {
    let tab: PullRequestTab
    let thread: ReviewThread
    let showsHunk: Bool

    var body: some View {
        let activity = tab.threadActivity
        if thread.isResolved && !activity.expanded.contains(thread.id) {
            Button { activity.expanded.insert(thread.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text(verbatim: resolvedSummary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .help("Show this resolved conversation")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                if showsHunk {
                    Divider()
                    HunkSnippet(hunk: thread.diffHunk)
                }
                ForEach(thread.comments) { comment in
                    Divider()
                    CommentView(tab: tab, thread: thread, comment: comment)
                }
                // A thread in the viewer's pending review takes no replies until it's submitted.
                if (thread.viewerCanReply && !thread.isPending) || activity.errors[thread.id] != nil {
                    Divider()
                    footer(activity)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).opacity(isHighlighted ? 1 : 0))
            .animation(.easeOut(duration: 0.6), value: isHighlighted)
            .task(id: isHighlighted) {
                guard isHighlighted, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                if activity.highlighted == thread.id { activity.highlighted = nil }
            }
            // Links in comments follow the conversation's: a PR opens in its tab.
            .environment(\.openURL, OpenURLAction { [tab] url in
                let inBrowserTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                guard !inBrowserTab, PullRequestLink(url: url) != nil else {
                    openInBrowser(url)
                    return .handled
                }
                followLink(url, inBrowserTab: false) { await tab.open($0) }
                return .handled
            })
        }
    }

    /// Just shown from the conversation, so outlined for a moment.
    private var isHighlighted: Bool {
        tab.threadActivity.highlighted == thread.id
    }

    /// `Resolved · 4 comments · login`, naming who started it.
    private var resolvedSummary: String {
        let count = thread.comments.count
        let starter = thread.comments.first?.author?.login
        return (["Resolved", "\(count) \(count == 1 ? "comment" : "comments")"] + (starter.map { [$0] } ?? [])).joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 8) {
            if thread.isResolved {
                Button { tab.threadActivity.expanded.remove(thread.id) } label: {
                    Label("Resolved", systemImage: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .help("Fold this resolved conversation")
            }
            Text(verbatim: place)
            if thread.isOutdated {
                Text("Outdated")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5)))
            }
            Spacer(minLength: 0)
            resolveButton
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Resolves the thread, or unresolves a resolved one, when the viewer may.
    @ViewBuilder
    private var resolveButton: some View {
        let resolve = !thread.isResolved
        if !thread.isPending, resolve ? thread.viewerCanResolve : thread.viewerCanUnresolve {
            if tab.threadActivity.resolving.contains(thread.id) {
                ProgressView().controlSize(.mini)
            }
            Button(resolve ? "Resolve conversation" : "Unresolve conversation") {
                Task { await tab.setResolved(resolve, thread: thread) }
            }
            .controlSize(.small)
            .disabled(tab.threadActivity.resolving.contains(thread.id))
        }
    }

    /// Why the last change didn't reach GitHub, then the reply being written or a button to
    /// start one.
    @ViewBuilder
    private func footer(_ activity: ThreadActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = activity.errors[thread.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.diffDanger)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(error)
            }
            if let draft = activity.replies[thread.id] {
                // The files stay behind the conversation, where the reply may be written too.
                ReplyComposer(tab: tab, thread: thread, draft: draft, takesFocus: tab.section == .files)
            } else if thread.viewerCanReply {
                Button("Reply…") { tab.startReply(to: thread) }
                    .controlSize(.small)
                    .help("Reply to this conversation; it posts at once, not as part of a review")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Which lines it's on, where it was made for an outdated thread.
    private var place: String {
        guard let lines = thread.lines else { return "On the file" }
        let side = thread.side == .left ? " (old)" : ""
        let prefix = thread.isOutdated && thread.line == nil ? "Was on " : ""
        let range = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)"
        let text = prefix + range + side
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Says over the conversation that a thread it asked to show can't be shown in the diff, and
/// why, offering a reply to it there instead, and its file when the PR changes it.
struct UnshownThreadNote: View {
    let tab: PullRequestTab
    let unshown: UnshownThread

    var body: some View {
        let thread = tab.reviewThread(unshown.threadId)
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(verbatim: "\(thread.map(place(of:)) ?? "This conversation") can't be shown in the diff: \(unshown.reason).")
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if unshown.isFileSelected {
                Button("Show File") {
                    tab.threadActivity.dismissUnshown()
                    tab.section = .files
                }
                .help("Show the file without the conversation")
            }
            if let thread, thread.viewerCanReply, !thread.isPending {
                Button("Reply…") { tab.replyInConversation(to: thread) }
                    .help("Reply to this conversation here; it posts at once, not as part of a review")
            }
            Button("Dismiss", systemImage: "xmark") { tab.threadActivity.dismissUnshown() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(maxWidth: 720)
        .padding(16)
    }
}

/// A reply to a thread written over the conversation, by the thread or in a sheet: the
/// thread's comments, then the composer the diff's threads use, which sends the same way. Esc
/// puts it away with the draft kept on the thread.
struct ConversationReply: View {
    let tab: PullRequestTab
    let threadId: String

    var body: some View {
        let activity = tab.threadActivity
        VStack(alignment: .leading, spacing: 10) {
            if let thread = tab.reviewThread(threadId) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "Reply on \(place(of: thread))")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Show in diff") { Task { await tab.showInDiff(thread) } }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Show this conversation on its line in the diff, keeping the reply")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                            if index > 0 { Divider() }
                            CommentView(tab: tab, thread: thread, comment: comment)
                        }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                if let error = activity.errors[thread.id] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.diffDanger)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(error)
                }
                if let draft = activity.replies[thread.id] {
                    ReplyComposer(tab: tab, thread: thread, draft: draft, escape: { activity.closeConversationReply() })
                        .font(.callout)
                }
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

/// A comment on the PR itself written over the conversation, by its "Add a comment…": the
/// composer the threads use, posting at once to the conversation. Esc puts it away with the
/// draft kept for the link to open again.
struct ConversationCommentView: View {
    let tab: PullRequestTab

    var body: some View {
        let comment = tab.conversationComment
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a comment")
                .font(.headline)
            if let error = comment.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.diffDanger)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(error)
            }
            if let draft = comment.draft {
                CommentComposer(
                    tab: tab,
                    draft: draft, caption: "Markdown. Posts to the conversation at once.",
                    actions: [ComposerAction(label: "Comment", help: "Comment on the pull request at once, not as part of a review") {
                        Task { await tab.sendConversationComment() }
                    }],
                    cancel: { tab.cancelConversationComment() },
                    escape: { comment.close() }
                )
                .font(.callout)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

/// An edit of one of the viewer's comments or review summaries written over the conversation,
/// by its "Edit": the editor the diff's thread comments use. Esc puts it away with the edit
/// kept for the link to open again.
struct ConversationEditView: View {
    let tab: PullRequestTab
    let commentId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.headline)
            if let edit = tab.commentEdits.edits[commentId] {
                CommentEditor(tab: tab, edit: edit, escape: { tab.commentEdits.closeConversationEdit() })
                    .font(.callout)
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    /// Whose it is, as GitHub also lets a repo's admins edit others' comments.
    private var title: String {
        let item = tab.conversation?.items.first { $0.id == commentId }
        let author = item?.actor ?? tab.conversation?.threads.lazy.flatMap(\.comments).first { $0.id == commentId }?.author
        let whose = author.map { $0.login == tab.viewerLogin ? "your" : "\($0.login)'s" } ?? "the"
        guard let item, case .review = item.event else { return "Edit \(whose) comment" }
        return "Edit \(whose) review's summary"
    }
}

/// An edit of a comment's or review's body: a spinner until its markdown arrives from GitHub,
/// then the composer, saving at once. Why the last save was refused shows over it.
struct CommentEditor: View {
    let tab: PullRequestTab
    let edit: CommentEdit
    /// What Esc does instead of cancelling, if anything.
    var escape: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = edit.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.diffDanger)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(error)
            }
            switch edit.phase {
            case .fetching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting the comment from GitHub…")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Cancel") { tab.cancelEdit(of: edit.commentId) }
                        .controlSize(.small)
                }
                .frame(height: 96)
            case let .fetchFailed(reason):
                HStack(spacing: 8) {
                    Label("Couldn't get the comment from GitHub: \(reason)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.diffDanger)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Cancel") { tab.cancelEdit(of: edit.commentId) }
                    Button("Retry") { Task { await tab.retryFetch(of: edit) } }
                }
                .controlSize(.small)
                .frame(minHeight: 96)
            case .editing:
                CommentComposer(
                    tab: tab,
                    draft: edit.draft, caption: "Markdown. Saves to GitHub at once.",
                    actions: [ComposerAction(label: "Save", help: "Save your edit to GitHub") { Task { await tab.saveEdit(of: edit.commentId) } }],
                    cancel: { tab.cancelEdit(of: edit.commentId) },
                    escape: escape
                )
            }
        }
    }
}

/// A reply being written to a thread, which posts at once rather than into a review.
private struct ReplyComposer: View {
    let tab: PullRequestTab
    let thread: ReviewThread
    let draft: CommentDraft
    /// What Esc does instead of cancelling, if anything.
    var escape: (() -> Void)?
    /// Whether it takes the focus when the draft asks, false while it's out of sight.
    var takesFocus = true

    var body: some View {
        CommentComposer(
            tab: tab,
            draft: draft, caption: "Markdown. Posts at once, not as part of a review.",
            actions: [ComposerAction(label: "Reply", help: "Reply at once, not as part of a review") { Task { await tab.sendReply(to: thread) } }],
            cancel: { tab.cancelReply(to: thread) },
            escape: escape,
            takesFocus: takesFocus
        )
    }
}

/// One comment: who wrote it and when, over its body. A hidden one is a line saying so, which
/// shows it when clicked. One the viewer may edit is edited in place of its body, and one they
/// may delete can be, after asking.
private struct CommentView: View {
    let tab: PullRequestTab
    let thread: ReviewThread
    let comment: ThreadComment

    var body: some View {
        let activity = tab.threadActivity
        if comment.isMinimized && !activity.expanded.contains(comment.id) {
            Button { activity.expanded.insert(comment.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                    Text(verbatim: hiddenSummary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .help("Show this hidden comment")
        } else {
            let edit = tab.commentEdits.edits[comment.id]
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: author).fontWeight(.semibold)
                    if comment.isSending || comment.isSaving {
                        ProgressView().controlSize(.mini)
                        Text(comment.isSending ? "Sending…" : "Saving…")
                            .foregroundStyle(.secondary)
                            .help(comment.isSending ? "On its way to GitHub" : "Your edit is on its way to GitHub")
                    } else {
                        TimelineView(.everyMinute) { _ in
                            Text(verbatim: comment.createdAt.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary)
                        }
                        .help(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if comment.isPending {
                        PendingBadge()
                    }
                    Spacer(minLength: 0)
                    if edit == nil, tab.canEdit(comment.id) {
                        Button("Edit…") { Task { await tab.startEdit(of: comment.id) } }
                            .controlSize(.small)
                            .help("Edit this comment")
                    }
                    if tab.canDelete(comment.id) || tab.threadActivity.deleting.contains(comment.id) {
                        DeleteCommentButton(tab: tab, thread: thread, comment: comment)
                    }
                }
                .font(.callout)
                if let edit {
                    CommentEditor(tab: tab, edit: edit)
                } else {
                    CommentBody(blocks: commentBlocks(comment.bodyHTML))
                        .background(QuoteSource(threadId: thread.id, bodyHTML: comment.bodyHTML))
                }
                // A pending comment can't be reacted to until its review is submitted, nor one
                // GitHub doesn't have yet.
                if !comment.isPending, !comment.isSending {
                    ReactionsRow(tab: tab, subjectId: comment.id, groups: comment.reactions)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var author: String {
        guard let login = comment.author?.login else { return "ghost" }
        return login == tab.viewer ? "\(login) (you)" : login
    }

    private var hiddenSummary: String {
        let reason = comment.minimizedReason.map { " as \($0.lowercased().replacingOccurrences(of: "_", with: " "))" } ?? ""
        return "\(comment.author?.login ?? "ghost")'s comment was hidden\(reason)"
    }
}

/// Deletes one of the viewer's comments after asking, with a spinner while it goes.
struct DeleteCommentButton: View {
    let tab: PullRequestTab
    let thread: ReviewThread
    let comment: ThreadComment
    @State private var confirmsDelete = false

    var body: some View {
        let isDeleting = tab.threadActivity.deleting.contains(comment.id)
        HStack(spacing: 6) {
            if isDeleting {
                ProgressView().controlSize(.mini)
            }
            Button("Delete…") { confirmsDelete = true }
                .controlSize(.small)
                .disabled(isDeleting)
                .help(comment.isPending ? "Delete this comment from your pending review" : "Delete this comment from GitHub")
        }
        .alert(comment.isPending ? "Delete this pending comment?" : "Delete this comment?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { Task { await tab.deleteComment(comment, in: thread) } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text(comment.isPending ? "It's in your review, not yet submitted, so no one else has seen it." : "It'll be gone from GitHub for everyone.")
        }
    }
}

/// One way to send a comment: its button's title and tooltip, and what it does.
struct ComposerAction {
    let label: String
    let help: String
    let send: () -> Void
}

/// A plain-text field for a comment in markdown, as the description's editor is: ⌘↩ sends by
/// the first of `actions`, which is the prominent button, ⌘⇧↩ by the second if there is one,
/// and Esc cancels, asking first if anything has been typed, or for an edit changed, unless
/// it's given something else to do.
struct CommentComposer: View {
    /// The PR it's written on, for its preview.
    let tab: PullRequestTab
    @Bindable var draft: CommentDraft
    let caption: String
    let actions: [ComposerAction]
    let cancel: () -> Void
    /// What Esc does instead of cancelling, such as putting a floating composer away.
    var escape: (() -> Void)?
    /// Whether it takes the focus when the draft asks, as when a quote is added to it.
    var takesFocus = true
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownEditor(
                text: $draft.text, isEditable: true, tab: tab, save: { send(actions.first) }, alternateSave: alternateSave, cancel: escape ?? cancelAsking,
                font: .systemFont(ofSize: NSFont.systemFontSize), minHeight: 96, focusRequests: takesFocus ? draft.focusRequests : 0
            )
            HStack(spacing: 8) {
                Text(caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(caption)
                Spacer(minLength: 0)
                Button("Cancel", action: cancelAsking)
                // The default sits last, at the trailing edge, as in a dialog.
                ForEach(Array(actions.enumerated().reversed()), id: \.offset) { index, action in
                    if index == 0 {
                        Button(action.label) { send(action) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!draft.canSend)
                            .help("\(action.help) (⌘↩)")
                    } else {
                        Button(action.label) { send(action) }
                            .disabled(!draft.canSend)
                            .help(index == 1 ? "\(action.help) (⌘⇧↩)" : action.help)
                    }
                }
            }
            .controlSize(.small)
        }
        .alert(isEdit ? "Discard your changes?" : "Discard this comment?", isPresented: $confirmsDiscard) {
            Button("Discard", role: .destructive, action: cancel)
            Button("Keep Writing", role: .cancel) {}
        } message: {
            Text(isEdit ? "The comment stays as it is on GitHub." : "It hasn't been posted to GitHub.")
        }
    }

    private var isEdit: Bool {
        draft.original != nil
    }

    private var alternateSave: (() -> Void)? {
        guard actions.count > 1 else { return nil }
        let action = actions[1]
        return { send(action) }
    }

    private func send(_ action: ComposerAction?) {
        if draft.canSend { action?.send() }
    }

    private func cancelAsking() {
        if draft.hasChanges {
            confirmsDiscard = true
        } else {
            cancel()
        }
    }
}

/// A comment's body, laid out natively from GitHub's rendering of it.
struct CommentBody: View {
    let blocks: [CommentBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .text(text, indent):
                    Text(text)
                        .padding(.leading, CGFloat(indent) * 16)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case let .code(code):
                    Text(verbatim: code)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                case let .quote(inner):
                    HStack(alignment: .top, spacing: 8) {
                        Capsule().fill(.quaternary).frame(width: 3)
                        CommentBody(blocks: inner).foregroundStyle(.secondary)
                    }
                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Marks where a thread comment's body is drawn, so text selected in it can be quoted into the
/// thread's reply.
struct QuoteSource: NSViewRepresentable {
    let threadId: String
    let bodyHTML: String

    final class Marker: NSView {
        var threadId = ""
        var bodyHTML = ""

        // Only marks the place; clicks go to the comment it's behind.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ view: Marker, context: Context) {
        view.threadId = threadId
        view.bodyHTML = bodyHTML
    }
}

/// Quotes the text selected in a thread comment's body, drawn natively in `window`, into the
/// thread's reply, as github.com's `r` does, and returns whether it's taking it. A selection in
/// a comment's body is made in the window's field editor for one of the body's blocks, and found
/// again in GitHub's rendering of the comment to be quoted as github.com would.
@MainActor
func quoteSelectedComment(in window: NSWindow, of tab: PullRequestTab) -> Bool {
    guard let editor = window.firstResponder as? NSTextView, !editor.isEditable, editor.selectedRange().length > 0,
          let field = editor.delegate as? NSTextField, let root = window.contentView else { return false }
    let center = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
    guard let source = quoteSource(at: center, in: root), let thread = tab.reviewThread(source.threadId), tab.takesQuote(thread) else { return false }
    let (range, text, html) = (editor.selectedRange(), editor.string, source.bodyHTML)
    Task {
        guard let markdown = await QuoteConverter.shared.markdown(selecting: range, of: text, inComment: html) else { return }
        tab.quoteInReply(markdown, to: thread)
    }
    return true
}

/// Marks a comment, or a thread, in the viewer's review not yet submitted.
private struct PendingBadge: View {
    var body: some View {
        Badge(text: "Pending", tint: .diffAttention)
            .help("In your pending review; no one else sees it until the review is submitted")
    }
}

/// The end of the diff an outdated thread was made on, as GitHub kept it.
private struct HunkSnippet: View {
    let hunk: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.isEmpty ? " " : line)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(of: line))
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 4)
    }

    /// The last few lines, which end on the commented one, as github.com shows.
    private var lines: [String] {
        Array(hunk.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().suffix(4).map(String.init))
    }

    private func background(of line: String) -> Color {
        if line.hasPrefix("+") { return Color(nsColor: DiffColors.additionBackground) }
        if line.hasPrefix("-") { return Color(nsColor: DiffColors.deletionBackground) }
        return .clear
    }
}

/// Sets a thread block in from the gutter, so it reads as belonging to the code above it, and
/// keeps it to a readable width.
private struct BlockInset: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.leading, 48)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.05))
    }
}

/// The blocks of a comment's HTML, worked out once per body while the app runs.
@MainActor
func commentBlocks(_ html: String) -> [CommentBlock] {
    if let blocks = parsedComments[html] { return blocks }
    let blocks = CommentBlock.blocks(fromHTML: html)
    parsedComments[html] = blocks
    return blocks
}

@MainActor private var parsedComments: [String: [CommentBlock]] = [:]

/// `path:line` for a thread, the conversation's name for where it is: its last line in the
/// current diff, or where it was made once outdated.
func place(of thread: ReviewThread) -> String {
    thread.lines.map { "\(thread.path):\($0.upperBound)" } ?? thread.path
}

/// The comment body drawn at `point`, in the window's coordinates, among `view`'s descendants.
@MainActor
private func quoteSource(at point: NSPoint, in view: NSView) -> QuoteSource.Marker? {
    for subview in view.subviews where !subview.isHidden {
        if let marker = subview as? QuoteSource.Marker, marker.convert(marker.bounds, to: nil).contains(point) { return marker }
        if let found = quoteSource(at: point, in: subview) { return found }
    }
    return nil
}
