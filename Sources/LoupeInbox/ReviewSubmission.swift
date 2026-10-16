import Foundation
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
    /// submitted or abandoned.
    public var isWritingSummary = false
    public internal(set) var isSubmitting = false
    /// Why GitHub refused the last submission or abandonment, until another is tried.
    public internal(set) var error: String?
    /// Whether the summary has been taken from the pending review yet, so it's only filled once.
    var hasStarted = false

    init() {}

    /// Closed and empty, for the next review.
    func reset() {
        body = ""
        isWritingSummary = false
        hasStarted = false
    }
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
    /// commenting or asking for changes needs a summary or comments in the pending review.
    public func canSubmitReview(as event: ReviewEvent) -> Bool {
        guard canReview, !reviewDraft.isSubmitting else { return false }
        let hasSummary = !reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return event == .approve || hasSummary || (pendingReview?.commentCount ?? 0) > 0
    }

    /// Submits the viewer's review with the summary and `event`: the pending review if there is
    /// one, else a new review at once. Then the conversation and the PR's status are fetched
    /// again, so the review shows and the review decision follows it. A refusal is kept to show,
    /// with the draft as it was.
    public func submitReview(as event: ReviewEvent) async {
        let draft = reviewDraft
        guard canSubmitReview(as: event) else { return }
        let summary = reviewSummary
        let reviewed = Set(placedThreads.filter(\.isPending).map(\.id))
        draft.isSubmitting = true
        draft.error = nil
        defer { draft.isSubmitting = false }
        do {
            if let pendingReview {
                try await client.submitReview(pendingReview.id, event: event, body: summary)
            } else {
                let head = if case let .ready(review) = phase { review.headOid } else { pullRequest.headRefOid }
                try await client.addReview(toPullRequest: id, commitId: head, body: summary.isEmpty ? nil : summary, event: event, threads: [])
            }
        } catch {
            draft.error = "Couldn't submit your review: \(error.localizedDescription)"
            await refreshThreads { $0.isPending }
            return
        }
        draft.reset()
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
        draft.reset()
        await refreshThreads { $0.isPending }
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
