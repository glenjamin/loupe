import Foundation
import LoupeCore
import LoupeGitHub
import LoupeModel
import Observation

/// The review the viewer is finishing: its summary, kept while the tab lives so closing the
/// popover loses nothing. The verdict is picked as it's submitted.
@Observable
@MainActor
public final class ReviewDraft {
    /// The summary, in markdown.
    public var body = ""
    /// Whether the summary is open to write, kept while switching between tabs; it closes once
    /// submitted or discarded.
    public var isWritingSummary = false
    /// Whether the list of the review's pending comments is open.
    public var isListingPending = false
    public internal(set) var isSubmitting = false
    /// Why GitHub refused the last submission or discard, until another is tried.
    public internal(set) var error: String?
    /// Whether the summary has been taken from the pending review yet, so it's only filled once.
    var hasStarted = false

    init() {}

    /// Closed and empty, for the next review.
    func reset() {
        body = ""
        isWritingSummary = false
        isListingPending = false
        hasStarted = false
    }
}

/// One of the viewer's pending comments, with what it answers.
public struct PendingComment: Sendable, Equatable, Identifiable {
    public let thread: ReviewThread
    public let comment: ThreadComment
    /// The comment before it in its thread, which it replies to; nil for one starting a thread.
    public let replyingTo: ThreadComment?

    public var id: String { comment.id }

    /// The line of code a comment starting a thread is on, without its diff marker: the last
    /// line of the hunk GitHub keeps, which ends on it.
    public var commentedCode: String? {
        guard replyingTo == nil, let last = thread.diffHunk.split(separator: "\n", omittingEmptySubsequences: false).last,
              !last.hasPrefix("@@") else { return nil }
        let code = last.dropFirst().trimmingCharacters(in: .whitespaces)
        return code.isEmpty ? nil : code
    }
}

extension PullRequestTab {
    /// The viewer's pending comments in the order the diff shows them: by file, then line,
    /// with those on a whole file or nowhere in the diff after a file's lines.
    public var pendingComments: [PendingComment] {
        let threads = (conversation?.threads ?? []).enumerated().sorted { a, b in
            let (left, right) = (a.element, b.element)
            if left.path != right.path { return left.path < right.path }
            let (leftLine, rightLine) = (left.lines?.upperBound ?? .max, right.lines?.upperBound ?? .max)
            return leftLine != rightLine ? leftLine < rightLine : a.offset < b.offset
        }
        return threads.flatMap { _, thread in
            thread.comments.enumerated().compactMap { index, comment in
                guard comment.isPending else { return nil }
                return PendingComment(thread: thread, comment: comment, replyingTo: index > 0 ? thread.comments[index - 1] : nil)
            }
        }
    }
}

extension PullRequestTab {
    /// The viewer's review not yet submitted, as last fetched.
    public var pendingReview: PendingReview? {
        conversation?.pendingReview
    }

    /// Whether the viewer can give the PR a verdict, approving it or asking for changes: it's
    /// open and someone else's, as GitHub refuses either from a PR's author.
    public var canReview: Bool {
        canStartReview && pullRequest.author != viewer
    }

    /// Whether the viewer can hold comments in a pending review and submit it: on any open PR,
    /// their own included, whose review can only be submitted as a comment.
    public var canStartReview: Bool {
        viewer != nil && pullRequest.state == .open
    }

    /// Whether the PR is the viewer's own, which GitHub won't let them approve or ask changes of.
    public var isOwnPullRequest: Bool {
        viewer != nil && pullRequest.author == viewer
    }

    /// Adds the comment being started to the viewer's pending review, starting the review with
    /// it if they have none; one on a commit goes in on that commit, as github.com's does. It shows pending on its line and in the conversation straight
    /// away, marked as sending until GitHub answers with its copy; then the threads are fetched
    /// again. A refusal takes it away and opens the draft again with the reason, and the
    /// threads are fetched anyway, so a review started or submitted elsewhere since is known
    /// when it's sent again.
    public func sendReviewComment() async {
        guard canStartReview, let comment = threadActivity.newComment, comment.takesReviewComments, comment.draft.canSend,
              case let .ready(review) = phase
        else { return }
        threadActivity.newCommentError = nil
        let anchor = comment.anchor
        let text = comment.draft.text
        let sending = sendingComment(text, isPending: true)
        threadActivity.newComment = nil
        let change = make(.comment(sending, thread: sendingThread(for: comment, in: review), startsThread: true, reviewId: pendingReview?.id))
        await storeOwnChanges()
        let added: (comment: ThreadComment, threadId: String?, reviewId: String)
        do {
            if comment.target.isWholePullRequest {
                let thread = DraftThread(
                    path: anchor.path, line: anchor.line, side: anchor.side.rawValue, startLine: comment.start?.line, startSide: comment.start?.side.rawValue, body: text
                )
                added = try await addToReview(thread, of: review.headOid)
            } else {
                added = try await addToReview(text, on: anchor, of: comment.target.commitOid, in: review)
            }
        } catch {
            undo(change)
            reopen(comment, because: "Couldn't add to your review: \(error.localizedDescription)")
            await storeOwnChanges()
            await refreshThreads { $0.isPending }
            return
        }
        confirm(change, comment: sending.id, as: added.comment, threadId: added.threadId, reviewId: added.reviewId)
        await storeOwnChanges()
        await refreshThreads { $0.isPending }
    }

    /// Fills the summary from the pending review's, the first time it's opened to write.
    public func startWritingSummary() {
        let draft = reviewDraft
        guard !draft.hasStarted else { return }
        draft.hasStarted = true
        if draft.body.isEmpty, let body = pendingReview?.body { draft.body = body }
    }

    /// The summary a review would be submitted with: the draft's, or the pending review's until
    /// the summary has been opened or written.
    public var reviewSummary: String {
        let draft = reviewDraft
        guard draft.body.isEmpty, !draft.hasStarted else { return draft.body }
        return pendingReview?.body ?? ""
    }

    /// Whether a review can be submitted with `event`: approving needs nothing more, but
    /// commenting or asking for changes needs a summary or comments in the pending review. On
    /// the viewer's own PR it can only be submitted as a comment.
    public func canSubmitReview(as event: ReviewEvent) -> Bool {
        guard event == .comment ? canStartReview : canReview, !reviewDraft.isSubmitting else { return false }
        let hasSummary = !reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return event == .approve || hasSummary || (pendingReview?.commentCount ?? 0) > 0
    }

    /// Submits the viewer's review with the summary and `event`: the pending review if there is
    /// one, else a new review at once. It shows in the conversation straight away, its comments
    /// no longer pending, marked as sending until GitHub answers; then the conversation and the
    /// PR's status are fetched again, so the review decision follows it. A refusal puts the
    /// review back as it was, with the draft, and says why.
    public func submitReview(as event: ReviewEvent) async {
        let draft = reviewDraft
        guard canSubmitReview(as: event) else { return }
        let summary = reviewSummary
        let reviewed = Set(placedThreads.filter(\.isPending).map(\.id))
        let pendingId = pendingReview?.id
        let saved = draft.saved
        draft.isSubmitting = true
        draft.error = nil
        defer { draft.isSubmitting = false }
        let sending = sendingReview(ReviewState(event), summary: summary, replacing: pendingId)
        draft.reset()
        let head = if case let .ready(review) = phase { review.headOid } else { pullRequest.headRefOid }
        // Until GitHub says otherwise, it's taken to be on the head shown, as a new review is.
        let change = make(.submitted(sending, commit: head))
        await storeOwnChanges()
        let posted: PostedReview
        do {
            if let pendingId {
                posted = try await client.submitReview(pendingId, event: event, body: summary)
            } else {
                posted = try await client.addReview(toPullRequest: id, commitId: head, body: summary.isEmpty ? nil : summary, event: event, threads: [])
            }
        } catch {
            undo(change)
            draft.restore(saved)
            draft.error = "Couldn't submit your review: \(error.localizedDescription)"
            await storeOwnChanges()
            await refreshThreads { $0.isPending }
            return
        }
        confirm(change, review: sending.id, as: posted)
        await storeOwnChanges()
        if let viewer {
            do {
                try await lists.viewerGave(ReviewVerdict(login: viewer, state: posted.state, submittedAt: posted.date, commitOid: head), on: id)
            } catch {
                log("Couldn't store your review of \(title): \(error)")
            }
        }
        await refreshConversation()
        // The review's comments are the viewer's own, so they show as submitted at once even
        // while new commits wait for a reload.
        placeThreads { reviewed.contains($0.id) }
        do {
            try await lists.checkStatuses(of: [id])
        } catch {
            log("Couldn't look up \(title) after reviewing it: \(error.localizedDescription)")
        }
    }

    /// Deletes the viewer's pending review and its comments. They go at once, and come back,
    /// with the summary, if GitHub refuses; then the threads are fetched again. Asking first is
    /// the view's job.
    public func discardReview() async {
        let draft = reviewDraft
        guard let pendingReview, !draft.isSubmitting else { return }
        let saved = draft.saved
        draft.isSubmitting = true
        draft.error = nil
        defer { draft.isSubmitting = false }
        draft.reset()
        let change = make(.discarded(reviewId: pendingReview.id))
        await storeOwnChanges()
        do {
            try await client.deleteReview(pendingReview.id)
        } catch {
            undo(change)
            draft.restore(saved)
            draft.error = "Couldn't discard your review: \(error.localizedDescription)"
            await storeOwnChanges()
            return
        }
        confirm(change)
        await refreshThreads { $0.isPending }
    }

    /// Deletes one of the viewer's pending comments, and its thread with it if it was the only
    /// comment. It goes at once, and comes back if GitHub refuses, saying why on the thread;
    /// then the threads are fetched again. GitHub keeps a pending review left with no comments,
    /// which would still show as pending, so one with no summary saved either is deleted too; a
    /// summary being written here is kept.
    public func deletePendingComment(_ comment: ThreadComment, in thread: ReviewThread) async {
        guard comment.isPending, !comment.isSending, !threadActivity.deleting.contains(comment.id) else { return }
        threadActivity.deleting.insert(comment.id)
        threadActivity.errors[thread.id] = nil
        defer { threadActivity.deleting.remove(comment.id) }
        let change = make(.deleted(commentId: comment.id))
        await storeOwnChanges()
        do {
            try await client.deleteReviewComment(comment.id)
        } catch {
            undo(change)
            threadActivity.errors[thread.id] = "Couldn't delete your comment: \(error.localizedDescription)"
            await storeOwnChanges()
            return
        }
        confirm(change)
        await refreshThreads { $0.isPending || $0.id == thread.id }
        guard let pendingReview, pendingReview.commentCount == 0, pendingReview.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reviewDraft.isSubmitting else { return }
        let emptied = make(.discarded(reviewId: pendingReview.id))
        await storeOwnChanges()
        do {
            try await client.deleteReview(pendingReview.id)
        } catch {
            undo(emptied)
            await storeOwnChanges()
            log("Couldn't delete the emptied pending review of \(title): \(error.localizedDescription)")
            return
        }
        confirm(emptied)
        await refreshThreads { $0.isPending }
    }
}

private extension PullRequestTab {
    /// Adds the thread to the viewer's pending review, or starts one with it, waiting for one
    /// already being started rather than starting another. Returns the comment, its thread's id
    /// where GitHub gave it, and the review's id.
    func addToReview(_ thread: DraftThread, of head: String) async throws -> (comment: ThreadComment, threadId: String?, reviewId: String) {
        if let reviewId = try await reviewBeingWritten() {
            let posted = try await client.addThread(thread, toReview: reviewId)
            return (posted.comment, posted.id, reviewId)
        }
        let started = try await startReview(on: head, holding: [thread])
        guard let comment = started.comments.first else { throw GitHubError.graphQL(["GitHub didn't return the comment"]) }
        return (comment, nil, started.id)
    }

    /// Adds a comment on `anchor` of `commit`'s own changes to the viewer's pending review,
    /// starting an empty one on the head first if they have none. GitHub places it by where the
    /// line is in its diff up to that commit, so that's found first.
    func addToReview(_ text: String, on anchor: DiffAnchor, of commit: String, in review: ReviewDiff) async throws -> (comment: ThreadComment, threadId: String?, reviewId: String) {
        let position = try await client.diffPosition(
            ofLine: anchor.line, side: anchor.side.rawValue, path: anchor.path, from: review.mergeBase, to: commit, in: pullRequest.repository
        )
        guard let position else { throw LineNotInGitHubDiff() }
        var reviewId = try await reviewBeingWritten()
        if reviewId == nil { reviewId = try await startReview(on: review.headOid, holding: []).id }
        guard let reviewId else { throw GitHubError.graphQL(["GitHub didn't return the review"]) }
        let comment = try await client.addCommitComment(text, path: anchor.path, position: position, commitId: commit, toReview: reviewId)
        return (comment, nil, reviewId)
    }

    /// The viewer's pending review's id, waiting for one being started; nil if they have none.
    func reviewBeingWritten() async throws -> String? {
        if let reviewId = pendingReview?.id { return reviewId }
        return try await reviewStart?.value.id
    }

    func startReview(on head: String, holding threads: [DraftThread]) async throws -> PostedReview {
        let (client, id) = (client, id)
        let start = Task { try await client.addReview(toPullRequest: id, commitId: head, body: nil, event: nil, threads: threads) }
        reviewStart = start
        defer { if reviewStart == start { reviewStart = nil } }
        return try await start.value
    }
}

/// GitHub's diff from the PR's base to a commit can leave out a line of the commit's own
/// changes, such as one the commit leaves as the base had it.
private struct LineNotInGitHubDiff: LocalizedError {
    var errorDescription: String? { "GitHub's diff of the pull request up to this commit doesn't show this line" }
}

private extension ReviewDraft {
    /// The summary and what's open, to put back if a submission is refused.
    struct Saved {
        let body: String
        let isWritingSummary: Bool
        let isListingPending: Bool
        let hasStarted: Bool
    }

    var saved: Saved {
        Saved(body: body, isWritingSummary: isWritingSummary, isListingPending: isListingPending, hasStarted: hasStarted)
    }

    func restore(_ saved: Saved) {
        body = saved.body
        isWritingSummary = saved.isWritingSummary
        isListingPending = saved.isListingPending
        hasStarted = saved.hasStarted
    }
}

private extension ReviewState {
    init(_ event: ReviewEvent) {
        self = switch event {
        case .approve: .approved
        case .requestChanges: .changesRequested
        case .comment: .commented
        }
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
