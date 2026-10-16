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
                CommentComposer(draft: comment.draft, caption: caption, actions: actions, cancel: { tab.cancelComment() })
            }
            .font(.callout)
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .modifier(BlockInset())
    }

    /// Where the viewer can review, a single comment posted at once and one into their review,
    /// as on github.com; ⌘↩ adds to a pending review, and otherwise posts at once.
    private var actions: [ComposerAction] {
        let atOnce = "Post this comment at once, not as part of a review"
        guard tab.canReview else {
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
        guard tab.canReview else { return "Markdown. Posts at once, not as part of a review." }
        return tab.pendingReview == nil ? "Markdown. ⌘↩ adds a single comment, posted at once." : "Markdown. ⌘↩ adds it to your pending review."
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
                ReplyComposer(tab: tab, thread: thread, draft: draft)
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

/// A reply being written to a thread, which posts at once rather than into a review.
private struct ReplyComposer: View {
    let tab: PullRequestTab
    let thread: ReviewThread
    let draft: CommentDraft
    /// What Esc does instead of cancelling, if anything.
    var escape: (() -> Void)?

    var body: some View {
        CommentComposer(
            draft: draft, caption: "Markdown. Posts at once, not as part of a review.",
            actions: [ComposerAction(label: "Reply", help: "Reply at once, not as part of a review") { Task { await tab.sendReply(to: thread) } }],
            cancel: { tab.cancelReply(to: thread) },
            escape: escape
        )
    }
}

/// One comment: who wrote it and when, over its body. A hidden one is a line saying so, which
/// shows it when clicked. One in the viewer's pending review can be deleted, after asking.
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: author).fontWeight(.semibold)
                    if comment.isSending {
                        ProgressView().controlSize(.mini)
                        Text("Sending…")
                            .foregroundStyle(.secondary)
                            .help("On its way to GitHub")
                    } else {
                        TimelineView(.everyMinute) { _ in
                            Text(verbatim: comment.createdAt.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary)
                        }
                        .help(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if comment.isPending {
                        PendingBadge()
                        Spacer(minLength: 0)
                        // GitHub has to know of it before it can be deleted.
                        if !comment.isSending {
                            DeletePendingCommentButton(tab: tab, thread: thread, comment: comment)
                        }
                    }
                }
                .font(.callout)
                CommentBody(blocks: commentBlocks(comment.bodyHTML))
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

/// Deletes one of the viewer's pending comments after asking, with a spinner while it goes.
struct DeletePendingCommentButton: View {
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
                .help("Delete this comment from your pending review")
        }
        .alert("Delete this pending comment?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { Task { await tab.deletePendingComment(comment, in: thread) } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("It's in your review, not yet submitted, so no one else has seen it.")
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
/// the first of `actions`, which is the prominent button, and Esc cancels, asking first if
/// anything has been typed, unless it's given something else to do.
struct CommentComposer: View {
    @Bindable var draft: CommentDraft
    let caption: String
    let actions: [ComposerAction]
    let cancel: () -> Void
    /// What Esc does instead of cancelling, such as putting a floating composer away.
    var escape: (() -> Void)?
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownTextView(text: $draft.text, isEditable: true, save: { send(actions.first) }, cancel: escape ?? cancelAsking, font: .systemFont(ofSize: NSFont.systemFontSize))
                .frame(height: 96)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
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
                            .help(action.help)
                    }
                }
            }
            .controlSize(.small)
        }
        .alert("Discard this comment?", isPresented: $confirmsDiscard) {
            Button("Discard", role: .destructive, action: cancel)
            Button("Keep Writing", role: .cancel) {}
        } message: {
            Text("It hasn't been posted to GitHub.")
        }
    }

    private func send(_ action: ComposerAction?) {
        if draft.canSend { action?.send() }
    }

    private func cancelAsking() {
        if draft.hasText {
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
