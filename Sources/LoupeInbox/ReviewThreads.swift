import Foundation
import LoupeCore
import LoupeGitHub
import LoupeModel
import Observation

/// A file's review threads as its diff shows them: each under the line it ends on, and the
/// rest, outdated, on the whole file or on a line the diff doesn't have, after the last row.
public struct FileThreads: Sendable, Equatable {
    /// Threads on lines in the diff, in the order GitHub lists them, grouped by line.
    public var anchored: [LineThreads]
    /// Threads with nowhere in the diff to go, in the order GitHub lists them.
    public var elsewhere: [ReviewThread]

    public var isEmpty: Bool { anchored.isEmpty && elsewhere.isEmpty }
}

/// The threads ending on one line of a diff.
public struct LineThreads: Sendable, Equatable {
    public var side: DiffAnchor.Side
    public var line: Int
    public var threads: [ReviewThread]
}

/// What the viewer is doing among a tab's threads: what they've opened up, the replies being
/// written, and changes on their way to GitHub. Kept while the tab lives, so moving between
/// files doesn't fold threads again or lose a draft.
@Observable
@MainActor
public final class ThreadActivity {
    /// Resolved threads opened to read, and hidden comments shown, by id.
    public var expanded: Set<String> = []
    /// The reply being written to each thread, by thread id.
    public internal(set) var replies: [String: CommentDraft] = [:]
    /// Why the last reply to, or change to, each thread didn't reach GitHub, by thread id.
    public internal(set) var errors: [String: String] = [:]
    /// Threads being resolved or unresolved, by id.
    public internal(set) var resolving: Set<String> = []
    /// The viewer's pending comments being deleted, by comment id.
    public internal(set) var deleting: Set<String> = []
    /// The comment being started on a line, one at a time.
    public internal(set) var newComment: NewComment?
    /// Why the last new comment didn't reach GitHub, until it's sent again or dropped.
    public internal(set) var newCommentError: String?
    /// The thread, by id, the diff is to scroll into view once it draws it, until it has.
    public internal(set) var revealing: String?
    /// The thread just shown from the conversation, marked for a moment so the eye finds it.
    public var highlighted: String?
    /// The thread the conversation last asked to show that the diff can't, and why.
    public internal(set) var unshown: UnshownThread?
    /// A thread the diff can't show being replied to over the conversation instead.
    public internal(set) var replyingApart: UnshownThread?

    init() {}

    /// Called once the diff has scrolled the thread into view.
    public func didReveal(_ id: String) {
        if revealing == id { revealing = nil }
    }

    /// Stops offering, or writing a reply to, a thread the diff can't show; the reply's draft
    /// itself is closed as any other is.
    public func dismissUnshown() {
        unshown = nil
        replyingApart = nil
    }
}

/// A review thread the diff can't show, and why, in words that follow "it can't be shown in the
/// diff: ".
public struct UnshownThread: Sendable, Equatable {
    public let threadId: String
    public let reason: String
    /// Whether its file is in the PR's changes and now selected, to show without the thread.
    public let isFileSelected: Bool
}

/// A comment being written on a line that has no thread of the viewer's making yet.
public struct NewComment {
    public let anchor: DiffAnchor
    public let draft: CommentDraft
}

/// A comment being written, as markdown.
@Observable
@MainActor
public final class CommentDraft {
    public var text = ""
    public internal(set) var isSending = false

    init() {}

    /// Whether there's anything to send.
    public var canSend: Bool {
        !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether closing it would lose something typed.
    public var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension PullRequestTab {
    /// Acts on a link to a thread from the conversation page.
    public func follow(_ link: ThreadLink) async {
        guard let thread = reviewThread(link.threadId) else { return }
        switch link.action {
        case .show: await showInDiff(thread, replying: false)
        case .reply: await showInDiff(thread, replying: true)
        case .resolve: await setResolved(true, thread: thread)
        case .unresolve: await setResolved(false, thread: thread)
        }
    }

    /// Shows the thread where the diff places it, in the whole PR's changes: its file selected,
    /// the files shown, and the thread opened, marked and scrolled into view once drawn, with a
    /// reply started if `replying`. One the diff can't show is said so over the conversation,
    /// its file selected if the PR changes it, and a reply to it is written there instead.
    public func showInDiff(_ thread: ReviewThread, replying: Bool) async {
        threadActivity.dismissUnshown()
        let canReply = replying && thread.viewerCanReply && !thread.isPending
        if let reason = whyDiffCannotShow(thread) {
            let isFileSelected = isInChanges(thread.path)
            if isFileSelected { selectedFile = thread.path }
            let unshown = UnshownThread(threadId: thread.id, reason: reason, isFileSelected: isFileSelected)
            if canReply {
                startReply(to: thread)
                threadActivity.replyingApart = unshown
            } else {
                threadActivity.unshown = unshown
            }
            return
        }
        if shownCommit != nil { await showCommit(nil) }
        selectedFile = thread.path
        section = .files
        if thread.isResolved { threadActivity.expanded.insert(thread.id) }
        threadActivity.revealing = thread.id
        threadActivity.highlighted = thread.id
        if canReply { startReply(to: thread) }
    }

    /// The thread with this id, as last fetched.
    public func reviewThread(_ id: String) -> ReviewThread? {
        conversation?.threads.first { $0.id == id }
    }

    /// The PR's review threads placed on `file`, as shown with any lines revealed around its
    /// hunks. Nil when one commit's changes are shown: threads belong to the whole PR's diff.
    public func threads(on file: FileDiff) -> FileThreads? {
        guard shownCommit == nil, conversation != nil else { return nil }
        var anchored: [LineThreads] = []
        var elsewhere: [ReviewThread] = []
        for thread in placedThreads where thread.path == file.path {
            guard !thread.isOutdated, !thread.isOnFile, let line = thread.line, file.has(line, on: thread.side) else {
                elsewhere.append(thread)
                continue
            }
            let side = DiffAnchor.Side(thread.side)
            if let index = anchored.firstIndex(where: { $0.side == side && $0.line == line }) {
                anchored[index].threads.append(thread)
            } else {
                anchored.append(LineThreads(side: side, line: line, threads: [thread]))
            }
        }
        return FileThreads(anchored: anchored, elsewhere: elsewhere)
    }

    /// How many threads on the file at `path` aren't resolved, hidden files' included. Nil when
    /// one commit's changes are shown, as its diff shows no threads.
    public func unresolvedThreadCount(of path: String) -> Int? {
        guard shownCommit == nil else { return nil }
        return conversation?.threads.count { $0.path == path && !$0.isResolved } ?? 0
    }

    /// The rows of a file a comment can be started on: every line of `file` as shown, those
    /// revealed around its hunks included, with unchanged lines on the new side as on
    /// github.com. Nil when one commit's changes are shown, as comments go on the whole PR's diff.
    public func commentableAnchors(of file: FileDiff) -> Set<DiffAnchor>? {
        guard shownCommit == nil else { return nil }
        return Set(file.hunks.flatMap(\.lines).map { line in
            switch line.kind {
            case let .context(_, new), let .addition(new): DiffAnchor(path: file.path, side: .right, line: new)
            case let .deletion(old): DiffAnchor(path: file.path, side: .left, line: old)
            }
        })
    }

    /// Opens a comment under a row, keeping one already being written there; one elsewhere
    /// with nothing typed is dropped, and one with text is kept, so it isn't lost.
    public func startComment(at anchor: DiffAnchor) {
        if let current = threadActivity.newComment {
            guard current.anchor != anchor, !current.draft.hasText, !current.draft.isSending else { return }
        }
        threadActivity.newComment = NewComment(anchor: anchor, draft: CommentDraft())
        threadActivity.newCommentError = nil
    }

    /// Drops the comment being started; asking first is the view's job.
    public func cancelComment() {
        guard threadActivity.newComment?.draft.isSending != true else { return }
        threadActivity.newComment = nil
        threadActivity.newCommentError = nil
    }

    /// Posts the new comment at once as a thread on its line, against the head commit the diff
    /// shows, whose line numbers it uses, then fetches the threads again to show it. A refusal
    /// keeps the draft open with the reason.
    public func sendComment() async {
        guard let comment = threadActivity.newComment, comment.draft.canSend, case let .ready(review) = phase else { return }
        comment.draft.isSending = true
        threadActivity.newCommentError = nil
        defer { comment.draft.isSending = false }
        let pullRequest = pullRequest
        let known = Set((conversation?.threads ?? []).map(\.id) + threadsOfShownDiff.map(\.id))
        do {
            try await client.addReviewComment(
                comment.draft.text, path: comment.anchor.path, line: comment.anchor.line, side: comment.anchor.side.rawValue,
                commitId: review.headOid, inPullRequest: pullRequest.number, of: pullRequest.repository
            )
        } catch {
            threadActivity.newCommentError = "Couldn't comment: \(error.localizedDescription)"
            return
        }
        if threadActivity.newComment?.draft === comment.draft { threadActivity.newComment = nil }
        let viewer = viewer
        await refreshThreads { !known.contains($0.id) && $0.comments.first?.author?.login == viewer }
    }

    /// Opens a reply under the thread, keeping one already being written.
    public func startReply(to thread: ReviewThread) {
        guard thread.viewerCanReply, threadActivity.replies[thread.id] == nil else { return }
        threadActivity.replies[thread.id] = CommentDraft()
    }

    /// Closes the thread's reply, dropping its draft; asking first is the view's job.
    public func cancelReply(to thread: ReviewThread) {
        guard threadActivity.replies[thread.id]?.isSending != true else { return }
        threadActivity.replies[thread.id] = nil
        threadActivity.errors[thread.id] = nil
    }

    /// Posts the thread's reply at once, then fetches the threads again to show it as GitHub
    /// has it. A refusal keeps the draft open with the reason.
    public func sendReply(to thread: ReviewThread) async {
        guard let draft = threadActivity.replies[thread.id], draft.canSend else { return }
        guard let first = thread.comments.first?.databaseId else {
            threadActivity.errors[thread.id] = "Couldn't reply: GitHub hasn't said which comment started this thread. Reload and try again."
            return
        }
        draft.isSending = true
        threadActivity.errors[thread.id] = nil
        defer { draft.isSending = false }
        let pullRequest = pullRequest
        do {
            try await client.replyToThread(startedBy: first, body: draft.text, inPullRequest: pullRequest.number, of: pullRequest.repository)
        } catch {
            threadActivity.errors[thread.id] = "Couldn't reply: \(error.localizedDescription)"
            return
        }
        if threadActivity.replies[thread.id] === draft { threadActivity.replies[thread.id] = nil }
        await refreshThreads { $0.id == thread.id }
    }

    /// Resolves the thread, or unresolves it. The change shows at once, and is put back if
    /// GitHub refuses it; a thread resolved here folds away, as on github.com.
    public func setResolved(_ resolved: Bool, thread: ReviewThread) async {
        guard resolved ? thread.viewerCanResolve : thread.viewerCanUnresolve, !threadActivity.resolving.contains(thread.id) else { return }
        threadActivity.resolving.insert(thread.id)
        threadActivity.errors[thread.id] = nil
        defer { threadActivity.resolving.remove(thread.id) }
        updateThread(thread.id) { $0.isResolved = resolved }
        if resolved { threadActivity.expanded.remove(thread.id) }
        do {
            try await client.setThreadResolved(resolved, threadId: thread.id)
        } catch {
            updateThread(thread.id) { $0.isResolved = !resolved }
            threadActivity.errors[thread.id] = "Couldn't \(resolved ? "resolve" : "unresolve") this conversation: \(error.localizedDescription)"
            if resolved { threadActivity.expanded.insert(thread.id) }
            return
        }
        await refreshThreads { $0.id == thread.id }
    }

    /// Takes the PR's review threads and the viewer's pending review from GitHub alone, which is
    /// much cheaper than the whole conversation, and stores them. A failure keeps what's shown.
    /// While new commits wait for a reload, only the threads the viewer just acted on change on
    /// the diff shown.
    func refreshThreads(placing actedOn: (ReviewThread) -> Bool) async {
        let fetched: ReviewThreads
        do {
            fetched = try await client.reviewThreads(ofPullRequest: id, viewer: viewer)
        } catch {
            log("Couldn't get the review threads of \(title): \(error.localizedDescription)")
            return
        }
        conversation?.threads = fetched.threads
        conversation?.pendingReview = fetched.pendingReview
        placeThreads(actedOn)
        do {
            try await store.replaceThreads(of: id, with: fetched.threads, pendingReview: fetched.pendingReview)
        } catch {
            log("Couldn't store the review threads of \(title): \(error)")
        }
    }

    /// Puts the conversation's threads, as just fetched, on the diff shown: all of them while
    /// it's of the PR's head. While new commits wait for a reload, only those the viewer acted
    /// on, and their pending ones GitHub no longer has, such as an abandoned review's, go.
    func placeThreads(_ actedOn: (ReviewThread) -> Bool) {
        guard pendingChange != nil else { return followPlacedThreads() }
        let threads = conversation?.threads ?? []
        for thread in threads where actedOn(thread) {
            threadsOfShownDiff.replaceOrAppend(thread)
        }
        let fetched = Set(threads.map(\.id))
        threadsOfShownDiff.removeAll { $0.isPending && !fetched.contains($0.id) }
    }

    /// Changes the thread wherever it's shown: in the conversation and placed on the diff.
    private func updateThread(_ id: String, _ change: (inout ReviewThread) -> Void) {
        if let index = threadsOfShownDiff.firstIndex(where: { $0.id == id }) { change(&threadsOfShownDiff[index]) }
        guard var conversation, let index = conversation.threads.firstIndex(where: { $0.id == id }) else { return }
        change(&conversation.threads[index])
        self.conversation = conversation
    }
}

private extension PullRequestTab {
    /// Why the whole PR's diff can't show the thread, or nil when it can: on a line, or after
    /// the file's last row for one with no line there, a hidden file's once it's diffed.
    func whyDiffCannotShow(_ thread: ReviewThread) -> String? {
        switch phase {
        case .ready: break
        case .noCheckout: return "there's no local checkout to diff"
        case .failed: return "the diff couldn't be produced"
        case .producing: return "the diff isn't ready yet"
        }
        guard isInChanges(thread.path) else { return "the PR no longer changes \(thread.path)" }
        guard placedThreads.contains(where: { $0.id == thread.id }) else { return "it's on commits newer than the diff shown; reload to see it there" }
        return nil
    }

    /// Whether the whole PR's changes have the file, hidden or not.
    func isInChanges(_ path: String) -> Bool {
        guard case let .ready(review) = phase else { return false }
        return review.changes.files.contains { $0.path == path } || review.changes.hidden.contains { $0.path == path }
    }
}

private extension [ReviewThread] {
    mutating func replaceOrAppend(_ thread: ReviewThread) {
        if let index = firstIndex(where: { $0.id == thread.id }) {
            self[index] = thread
        } else {
            append(thread)
        }
    }
}

private extension FileDiff {
    /// Whether a row of the diff has `line` on `side`: the new side for RIGHT, the old for LEFT.
    func has(_ line: Int, on side: ReviewThread.Side) -> Bool {
        hunks.contains { hunk in
            hunk.lines.contains { (side == .right ? $0.newLine : $0.oldLine) == line }
        }
    }
}

private extension DiffAnchor.Side {
    init(_ side: ReviewThread.Side) {
        self = side == .left ? .left : .right
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
