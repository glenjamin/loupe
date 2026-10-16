import Foundation
import LoupeGitHub
import LoupeModel
import Observation

/// The review the viewer is finishing: its summary and verdict, kept while the tab lives so
/// closing the popover loses nothing.
@Observable
@MainActor
public final class ReviewDraft {
    /// The summary, in markdown.
    public var body = ""
    public var event = ReviewEvent.comment
    public internal(set) var isSubmitting = false
    /// Why GitHub refused the last submission or abandonment, until another is tried.
    public internal(set) var error: String?
    /// Whether the summary has been taken from the pending review yet, so it's only filled once.
    var hasStarted = false

    init() {}
}

extension PullRequestTab {
    /// The viewer's review not yet submitted, as last fetched.
    public var pendingReview: PendingReview? {
        conversation?.pendingReview
    }

    /// Whether the viewer can review the PR from here: it's open and someone else's. Their own
    /// PR's place is taken by its reviewers and Merge.
    public var canReview: Bool {
        guard let viewer else { return false }
        return pullRequest.state == .open && pullRequest.author != viewer
    }

    /// Whether the PR is the viewer's own, which GitHub won't let them approve or ask changes of.
    public var isOwnPullRequest: Bool {
        viewer != nil && pullRequest.author == viewer
    }

    /// Adds the comment being started to the viewer's pending review, starting the review with
    /// it if they have none, then fetches the threads again to show it pending. A refusal keeps
    /// the draft open with the reason, and the threads are fetched anyway, so a review started
    /// or submitted elsewhere since is known when it's sent again.
    public func sendReviewComment() async {
        guard canReview, let comment = threadActivity.newComment, comment.draft.canSend, case let .ready(review) = phase else { return }
        comment.draft.isSending = true
        threadActivity.newCommentError = nil
        defer { comment.draft.isSending = false }
        let anchor = comment.anchor
        let thread = DraftThread(path: anchor.path, line: anchor.line, side: anchor.side.rawValue, body: comment.draft.text)
        do {
            if let pendingReview {
                try await client.addThread(thread, toReview: pendingReview.id)
            } else {
                try await client.addReview(toPullRequest: id, commitId: review.headOid, body: nil, event: nil, threads: [thread])
            }
        } catch {
            threadActivity.newCommentError = "Couldn't add to your review: \(error.localizedDescription)"
            await refreshThreads { $0.isPending }
            return
        }
        if threadActivity.newComment?.draft === comment.draft { threadActivity.newComment = nil }
        await refreshThreads { $0.isPending }
    }

    /// Fills the summary from the pending review's, the first time the review is opened to finish.
    public func startFinishingReview() {
        let draft = reviewDraft
        guard !draft.hasStarted else { return }
        draft.hasStarted = true
        if draft.body.isEmpty, let body = pendingReview?.body { draft.body = body }
    }

    /// Whether there's a review to submit: approving needs nothing more, but commenting or asking
    /// for changes needs a summary or comments in the pending review.
    public var canSubmitReview: Bool {
        let draft = reviewDraft
        guard canReview, !draft.isSubmitting else { return false }
        if isOwnPullRequest && draft.event != .comment { return false }
        let hasBody = !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return draft.event == .approve || hasBody || (pendingReview?.commentCount ?? 0) > 0
    }

    /// Submits the viewer's review with the draft's summary and verdict: the pending review if
    /// there is one, else a new review at once. Then the conversation and the PR's status are
    /// fetched again, so the review shows and the review decision follows it. A refusal is kept
    /// to show, with the draft as it was.
    public func submitReview() async {
        let draft = reviewDraft
        guard canSubmitReview else { return }
        let reviewed = Set(placedThreads.filter(\.isPending).map(\.id))
        draft.isSubmitting = true
        draft.error = nil
        defer { draft.isSubmitting = false }
        do {
            if let pendingReview {
                try await client.submitReview(pendingReview.id, event: draft.event, body: draft.body)
            } else {
                let head = if case let .ready(review) = phase { review.headOid } else { pullRequest.headRefOid }
                try await client.addReview(toPullRequest: id, commitId: head, body: draft.body.isEmpty ? nil : draft.body, event: draft.event, threads: [])
            }
        } catch {
            draft.error = "Couldn't submit your review: \(error.localizedDescription)"
            await refreshThreads { $0.isPending }
            return
        }
        draft.body = ""
        draft.event = .comment
        draft.hasStarted = false
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

    /// Deletes the viewer's pending review and its comments, then fetches the threads again so
    /// they go. Asking first is the view's job.
    public func abandonReview() async {
        let draft = reviewDraft
        guard let pendingReview, !draft.isSubmitting else { return }
        draft.isSubmitting = true
        draft.error = nil
        defer { draft.isSubmitting = false }
        do {
            try await client.deleteReview(pendingReview.id)
        } catch {
            draft.error = "Couldn't abandon your review: \(error.localizedDescription)"
            return
        }
        draft.body = ""
        draft.event = .comment
        draft.hasStarted = false
        await refreshThreads { $0.isPending }
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
