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
    /// The thread, by id, whose reply is being written over the conversation, by its place in
    /// the page; its draft is in `replies`, as the diff's are.
    public internal(set) var replyingInConversation: String?

    init() {}

    /// Called once the diff has scrolled the thread into view.
    public func didReveal(_ id: String) {
        if revealing == id { revealing = nil }
    }

    /// Stops saying a thread can't be shown in the diff.
    public func dismissUnshown() {
        unshown = nil
    }

    /// Puts away the reply being written over the conversation, keeping its draft on the
    /// thread, where the diff shows it and the conversation's "Reply…" opens it again.
    public func closeConversationReply() {
        replyingInConversation = nil
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

/// A comment being written on a line, or a range of lines, that has no thread of the viewer's
/// making yet.
public struct NewComment {
    /// The line it goes under: the last of a range.
    public let anchor: DiffAnchor
    /// The first line of a comment on several, in the same hunk; nil for one line.
    public let start: DiffAnchor?
    /// The changes it was started on, whose lines it's numbered in.
    public let target: CommentTarget
    public let draft: CommentDraft

    /// Whether it can go into a pending review: anything on the whole PR's diff, and one line of
    /// a commit, as GitHub's only way to put a comment on another commit into a review takes no
    /// range.
    public var takesReviewComments: Bool { target.isOnHead || start == nil }
}

/// The commit a new comment on the changes shown is anchored to, as GitHub takes it.
public struct CommentTarget: Sendable, Equatable {
    public let commitOid: String
    /// The whole PR's diff, rather than one commit's own changes or those since an earlier head.
    public let isWholePullRequest: Bool
    /// Whether its lines are numbered as the head's, as the whole PR's diff and the changes
    /// since an earlier head up to it are on their new side, so a comment goes on the head as
    /// one on the whole PR's diff does, and the head's threads show on those lines.
    public let isOnHead: Bool
    /// Whether deleted lines take comments. GitHub numbers a deleted line in the PR's base, so
    /// only a commit whose parent is that base can number them the same way.
    public let takesDeletedLines: Bool
}

/// A comment being written, as markdown. It closes as it's sent, the comment showing in its
/// thread at once, and opens again as it was if GitHub refuses it.
@Observable
@MainActor
public final class CommentDraft {
    public var text = ""
    /// The markdown as GitHub had it, for a draft editing a comment rather than writing one.
    public internal(set) var original: String?
    /// Counts the times its composer was asked to take the focus, with the cursor at the end,
    /// as when a quote is added to it.
    public internal(set) var focusRequests = 0

    init() {}

    /// Whether there's anything to send: some text, and for an edit, a change.
    public var canSend: Bool {
        hasText && text != original
    }

    /// Whether there's any text in it, besides whitespace.
    public var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether closing it would lose something typed: any text, or for an edit, any change.
    public var hasChanges: Bool {
        original.map { text != $0 } ?? hasText
    }
}

extension PullRequestTab {
    /// Acts on a link to a thread from the conversation page.
    public func follow(_ link: ThreadLink) async {
        guard let thread = reviewThread(link.threadId) else { return }
        switch link.action {
        case .show: await showInDiff(thread)
        case .reply: replyInConversation(to: thread)
        case .resolve: await setResolved(true, thread: thread)
        case .unresolve: await setResolved(false, thread: thread)
        }
    }

    /// Shows the thread where the diff places it, in the whole PR's changes: its file selected,
    /// the files shown, and the thread opened, marked and scrolled into view once drawn. One the
    /// diff can't show is said so over the conversation, its file selected if the PR changes it.
    public func showInDiff(_ thread: ReviewThread) async {
        threadActivity.dismissUnshown()
        threadActivity.closeConversationReply()
        if let reason = whyDiffCannotShow(thread) {
            let isFileSelected = isInChanges(thread.path)
            if isFileSelected { selectedFile = thread.path }
            threadActivity.unshown = UnshownThread(threadId: thread.id, reason: reason, isFileSelected: isFileSelected)
            return
        }
        if shownChoice != .all { await show(.all) }
        selectedFile = thread.path
        section = .files
        if thread.isResolved { threadActivity.expanded.insert(thread.id) }
        threadActivity.revealing = thread.id
        threadActivity.highlighted = thread.id
    }

    /// Opens a reply to the thread over the conversation, where it's being read, keeping one
    /// already being written to it, whether the diff can show the thread or not.
    public func replyInConversation(to thread: ReviewThread) {
        guard thread.viewerCanReply, !thread.isPending else { return }
        threadActivity.dismissUnshown()
        startReply(to: thread)
        threadActivity.replyingInConversation = thread.id
    }

    /// The thread with this id, as last fetched.
    public func reviewThread(_ id: String) -> ReviewThread? {
        conversation?.threads.first { $0.id == id }
    }

    /// The PR's review threads placed on `file`, as shown with any lines revealed around its
    /// hunks. On one commit's changes, only those made on that commit show, on the lines they
    /// were made on, as github.com shows them there; the rest belong to the whole PR's diff.
    /// The changes since an earlier head show the head's threads on their new side's lines.
    /// Nil when nothing anchors to the changes shown.
    public func threads(on file: FileDiff) -> FileThreads? {
        guard let target = commentTarget, conversation != nil else { return nil }
        var anchored: [LineThreads] = []
        var elsewhere: [ReviewThread] = []
        let threads = target.isOnHead ? placedThreads : (conversation?.threads ?? []).filter { $0.originalCommitOid == target.commitOid }
        for thread in threads where thread.path == file.path {
            guard let lines = placedLines(of: thread), file.has(lines.upperBound, on: thread.side),
                  target.takesDeletedLines || thread.side == .right
            else {
                if target.isWholePullRequest { elsewhere.append(thread) }
                continue
            }
            let (side, line) = (DiffAnchor.Side(thread.side), lines.upperBound)
            if let index = anchored.firstIndex(where: { $0.side == side && $0.line == line }) {
                anchored[index].threads.append(thread)
            } else {
                anchored.append(LineThreads(side: side, line: line, threads: [thread]))
            }
        }
        return FileThreads(anchored: anchored, elsewhere: elsewhere)
    }

    /// The lines a thread is on in the changes shown: where it is now on the whole PR's diff,
    /// or where it was made on one commit's. Nil where it has no lines there: outdated, on the
    /// whole file, or made on another commit.
    public func placedLines(of thread: ReviewThread) -> ClosedRange<Int>? {
        guard let target = commentTarget, !thread.isOnFile else { return nil }
        let (start, end) = if target.isOnHead {
            thread.isOutdated ? (nil, nil) : (thread.startLine, thread.line)
        } else {
            thread.originalCommitOid == target.commitOid ? (thread.originalStartLine, thread.originalLine) : (nil, nil)
        }
        guard let end else { return nil }
        return min(start ?? end, end)...end
    }

    /// Where new comments on the changes shown go: the PR's head for its whole diff, or the
    /// commit for one commit's changes, including changes since an earlier head that are
    /// exactly one commit's. Other changes since an earlier head, several commits' or those
    /// replayed across a rebase, go on the head too, on their new side only, as their deleted
    /// lines are the earlier head's. Nil for changes that don't end at the head.
    public var commentTarget: CommentTarget? {
        guard case let .ready(review) = phase else { return nil }
        if shownChoice == .all {
            return CommentTarget(commitOid: review.headOid, isWholePullRequest: true, isOnHead: true, takesDeletedLines: true)
        }
        guard let range = shownRange else { return nil }
        if let commit = review.commits.first(where: { $0.range == range }) {
            return CommentTarget(commitOid: commit.oid, isWholePullRequest: false, isOnHead: false, takesDeletedLines: range.base == review.mergeBase)
        }
        guard case .since = shownChoice, range.head == review.headOid else { return nil }
        return CommentTarget(commitOid: review.headOid, isWholePullRequest: false, isOnHead: true, takesDeletedLines: false)
    }

    /// How many threads on the file at `path` aren't resolved, hidden files' included. Nil when
    /// only some of the PR's changes are shown, as their diff shows no threads.
    public func unresolvedThreadCount(of path: String) -> Int? {
        guard shownChoice == .all else { return nil }
        return conversation?.threads.count { $0.path == path && !$0.isResolved } ?? 0
    }

    /// The rows of a file a comment can be started on: every line of `file` as shown, those
    /// revealed around its hunks included, with unchanged lines on the new side as on
    /// github.com, and deleted lines only where the commit numbers them as GitHub does. Nil
    /// when the changes shown have no commit to anchor a comment to, and for a file the
    /// changes since an earlier head show that the PR doesn't change, as GitHub takes comments
    /// only on the PR's files.
    public func commentableAnchors(of file: FileDiff) -> Set<DiffAnchor>? {
        guard let target = commentTarget else { return nil }
        if target.isOnHead, !target.isWholePullRequest, !isChanged(file.path) { return nil }
        return Set(file.hunks.flatMap(\.lines).map { $0.anchor(in: file.path) }.filter { target.takesDeletedLines || $0.side == .right })
    }

    /// Opens a comment under a row, keeping one already being written there; one elsewhere
    /// with nothing typed is dropped, and one with text is kept, so it isn't lost. With `start`,
    /// a row before it in the same hunk of the diff as produced, it's on every line from there,
    /// as GitHub takes a comment on several lines; a range it can't take, such as one across
    /// hunks or onto revealed lines, starts a comment on `anchor` alone.
    public func startComment(at anchor: DiffAnchor, from start: DiffAnchor? = nil) {
        guard let target = commentTarget else { return }
        let start = start.flatMap { start -> DiffAnchor? in
            guard start != anchor, let file = producedFile(anchor.path), file.anchors(from: start, to: anchor) != nil else { return nil }
            return start
        }
        if let current = threadActivity.newComment {
            guard current.anchor != anchor || current.start != start || current.target != target, !current.draft.hasText else { return }
        }
        threadActivity.newComment = NewComment(anchor: anchor, start: start, target: target, draft: CommentDraft())
        threadActivity.newCommentError = nil
    }

    /// The comment being started on the changes shown, if it was started on them.
    public var shownNewComment: NewComment? {
        guard let comment = threadActivity.newComment, comment.target == commentTarget else { return nil }
        return comment
    }

    /// The rows of `file`, as shown, that the comment being started there covers: its range's,
    /// or its one line.
    public func commentedAnchors(of file: FileDiff) -> Set<DiffAnchor> {
        guard let comment = shownNewComment, comment.anchor.path == file.path else { return [] }
        guard let start = comment.start else { return [comment.anchor] }
        return Set(file.anchors(from: start, to: comment.anchor) ?? [comment.anchor])
    }

    /// The file at `path` in the changes shown, as produced, without lines revealed around it:
    /// one to review, or a hidden one once diffed.
    func producedFile(_ path: String) -> FileDiff? {
        guard case let .ready(changes)? = shownChanges else { return nil }
        if let file = changes.files.first(where: { $0.path == path }) { return file }
        if case let .ready(file)? = hiddenFileDiff(of: path) { return file }
        return nil
    }

    /// Drops the comment being started; asking first is the view's job.
    public func cancelComment() {
        threadActivity.newComment = nil
        threadActivity.newCommentError = nil
    }

    /// Posts the new comment at once as a thread on its lines, against the commit it was started
    /// on, whose line numbers it uses: the head of the whole PR's diff, or one commit. It shows
    /// there and in the conversation straight away, marked as sending until GitHub answers with
    /// its copy; then the threads are fetched again in case of anything else new. A refusal
    /// takes it away and opens the draft again with the reason. Nothing posts while the viewer
    /// has a review pending, as GitHub refuses a comment at once then.
    public func sendComment() async {
        guard pendingReview == nil, let comment = threadActivity.newComment, comment.draft.canSend, case let .ready(review) = phase else { return }
        threadActivity.newCommentError = nil
        let pullRequest = pullRequest
        let known = Set((conversation?.threads ?? []).map(\.id) + threadsOfShownDiff.map(\.id))
        let text = comment.draft.text
        let sending = sendingComment(text, isPending: false)
        threadActivity.newComment = nil
        let change = make(.comment(sending, thread: sendingThread(for: comment, in: review), startsThread: true, reviewId: nil))
        await storeOwnChanges()
        let posted: ThreadComment
        do {
            posted = try await client.addReviewComment(
                text, path: comment.anchor.path, line: comment.anchor.line, side: comment.anchor.side.rawValue,
                start: comment.start.map { ($0.line, $0.side.rawValue) }, commitId: comment.target.commitOid,
                inPullRequest: pullRequest.number, of: pullRequest.repository
            )
        } catch {
            undo(change)
            reopen(comment, because: "Couldn't comment: \(error.localizedDescription)")
            await storeOwnChanges()
            return
        }
        confirm(change, comment: sending.id, as: posted, threadId: nil, reviewId: nil)
        await storeOwnChanges()
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
        threadActivity.replies[thread.id] = nil
        threadActivity.errors[thread.id] = nil
        if threadActivity.replyingInConversation == thread.id { threadActivity.closeConversationReply() }
    }

    /// Posts the thread's reply at once. It shows in the thread straight away, marked as sending
    /// until GitHub answers with its copy; then the threads are fetched again in case of
    /// anything else new. A refusal takes it away and opens the draft again with the reason,
    /// over the conversation too if that's where it was written.
    public func sendReply(to thread: ReviewThread) async {
        guard let draft = threadActivity.replies[thread.id], draft.canSend else { return }
        guard let first = thread.comments.first?.databaseId else {
            threadActivity.errors[thread.id] = "Couldn't reply: GitHub hasn't said which comment started this thread. Reload and try again."
            return
        }
        threadActivity.errors[thread.id] = nil
        let pullRequest = pullRequest
        let text = draft.text
        let wasInConversation = threadActivity.replyingInConversation == thread.id
        let sending = sendingComment(text, isPending: false)
        threadActivity.replies[thread.id] = nil
        if wasInConversation { threadActivity.closeConversationReply() }
        let change = make(.comment(sending, thread: thread, startsThread: false, reviewId: nil))
        await storeOwnChanges()
        let posted: ThreadComment
        do {
            posted = try await client.replyToThread(startedBy: first, body: text, inPullRequest: pullRequest.number, of: pullRequest.repository)
        } catch {
            undo(change)
            reopen(draft, replyingTo: thread.id, inConversation: wasInConversation)
            threadActivity.errors[thread.id] = "Couldn't reply: \(error.localizedDescription)"
            await storeOwnChanges()
            return
        }
        confirm(change, comment: sending.id, as: posted, threadId: nil, reviewId: nil)
        await storeOwnChanges()
        await refreshThreads { $0.id == thread.id }
    }

    /// Resolves the thread, or unresolves it. The change shows at once, and is put back if
    /// GitHub refuses it; a thread resolved here folds away, as on github.com.
    public func setResolved(_ resolved: Bool, thread: ReviewThread) async {
        guard resolved ? thread.viewerCanResolve : thread.viewerCanUnresolve, !threadActivity.resolving.contains(thread.id) else { return }
        threadActivity.resolving.insert(thread.id)
        threadActivity.errors[thread.id] = nil
        defer { threadActivity.resolving.remove(thread.id) }
        let change = make(.resolved(threadId: thread.id, resolved, by: viewer))
        if resolved { threadActivity.expanded.remove(thread.id) }
        await storeOwnChanges()
        do {
            try await client.setThreadResolved(resolved, threadId: thread.id)
        } catch {
            undo(change)
            threadActivity.errors[thread.id] = "Couldn't \(resolved ? "resolve" : "unresolve") this conversation: \(error.localizedDescription)"
            if resolved { threadActivity.expanded.insert(thread.id) }
            await storeOwnChanges()
            return
        }
        confirm(change)
        await refreshThreads { $0.id == thread.id }
    }

    /// Takes the PR's review threads and the viewer's pending review from GitHub alone, which is
    /// much cheaper than the whole conversation, and stores them, with any of the viewer's
    /// changes GitHub hadn't answered for when they were asked for made again over them. A
    /// failure keeps what's shown. While new commits wait for a reload, only the threads the
    /// viewer just acted on change on the diff shown.
    func refreshThreads(placing actedOn: (ReviewThread) -> Bool) async {
        let started = startFetch()
        defer { endFetch(started) }
        let fetched: ReviewThreads
        do {
            fetched = try await client.reviewThreads(ofPullRequest: id, viewer: viewer)
        } catch {
            log("Couldn't get the review threads of \(title): \(error.localizedDescription)")
            return
        }
        if var updated = conversation {
            updated.threads = fetched.threads
            updated.pendingReview = fetched.pendingReview
            remakeOwnChanges(over: &updated, fetchedFrom: started)
            conversation = updated
        }
        placeThreads(actedOn)
        await storeOwnChanges()
    }

    /// Puts the conversation's threads, as just fetched, on the diff shown: all of them while
    /// it's of the PR's head. While new commits wait for a reload, only those the viewer acted
    /// on, and their own GitHub no longer has, go: an abandoned review's, or one shown while it
    /// was sent that GitHub now has under its own id.
    func placeThreads(_ actedOn: (ReviewThread) -> Bool) {
        guard pendingChange != nil else { return followPlacedThreads() }
        let threads = conversation?.threads ?? []
        for thread in threads where actedOn(thread) {
            threadsOfShownDiff.replaceOrAppend(thread)
        }
        let fetched = Set(threads.map(\.id))
        threadsOfShownDiff.removeAll { ($0.isPending || OwnChange.isProvisional($0.id)) && !fetched.contains($0.id) }
    }
}

extension PullRequestTab {
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

extension PullRequestTab {
    /// Opens a refused new comment again as it was, saying why, unless another with something
    /// typed has been started since; that's kept, and the refused text is quoted with the
    /// reason so it isn't lost.
    func reopen(_ comment: NewComment, because reason: String) {
        if let current = threadActivity.newComment, current.draft.hasText {
            threadActivity.newCommentError = "\(reason)\n\nWhat wasn't sent: \(comment.draft.text)"
            return
        }
        threadActivity.newComment = comment
        threadActivity.newCommentError = reason
    }

    /// Opens a refused reply again as it was, over the conversation if it was written there. A
    /// reply to the thread started since keeps what's typed in it, after the refused text.
    func reopen(_ draft: CommentDraft, replyingTo threadId: String, inConversation: Bool) {
        if let current = threadActivity.replies[threadId], current.hasText {
            current.text = draft.text + "\n\n" + current.text
        } else {
            threadActivity.replies[threadId] = draft
        }
        if inConversation, threadActivity.replyingInConversation == nil { threadActivity.replyingInConversation = threadId }
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

extension FileDiff {
    /// Whether a row of the diff has `line` on `side`: the new side for RIGHT, the old for LEFT.
    func has(_ line: Int, on side: ReviewThread.Side) -> Bool {
        hunks.contains { hunk in
            hunk.lines.contains { (side == .right ? $0.newLine : $0.oldLine) == line }
        }
    }

    /// The rows from `start` to `end`, in order, when both are in one hunk with `start` first.
    func anchors(from start: DiffAnchor, to end: DiffAnchor) -> [DiffAnchor]? {
        for hunk in hunks {
            let anchors = hunk.lines.map { $0.anchor(in: path) }
            guard let first = anchors.firstIndex(of: start), let last = anchors.firstIndex(of: end) else { continue }
            return first < last ? Array(anchors[first...last]) : nil
        }
        return nil
    }
}

extension DiffLine {
    /// Where a comment on the row goes: an unchanged or added line on the new side, as on
    /// github.com, a deleted one on the old.
    func anchor(in path: String) -> DiffAnchor {
        switch kind {
        case let .context(_, new), let .addition(new): DiffAnchor(path: path, side: .right, line: new)
        case let .deletion(old): DiffAnchor(path: path, side: .left, line: old)
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
