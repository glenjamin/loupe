import Foundation

/// A reviewer as GitHub's "Reviewers" sidebar shows them: asked and waiting, or with the outcome
/// of their latest review.
public struct ReviewerStatus: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// Asked to review and hasn't since, including when asked again after reviewing.
        case requested
        case approved
        case changesRequested
        case commented
        /// Their review was dismissed, so it no longer counts.
        case dismissed
    }

    public var reviewer: Reviewer
    public var state: State

    public init(reviewer: Reviewer, state: State) {
        self.reviewer = reviewer
        self.state = state
    }

    public var id: String { reviewer.id }

    /// Whether they can be asked again: they've reviewed, aren't already asked, and GitHub gave
    /// the id a request needs.
    public var canReRequest: Bool {
        state != .requested && reviewer.nodeId != nil
    }
}

extension Conversation {
    /// The PR's reviewers, or nil where they aren't shown: they are on the viewer's own PRs,
    /// where asking for reviews is the viewer's job. On anyone else's the place is kept for the
    /// viewer's own review. A PR whose conversation hasn't arrived yet has none.
    public static func reviewers(of conversation: Conversation?, author: String?, viewer: String?) -> [ReviewerStatus]? {
        guard let viewer, author == viewer else { return nil }
        return conversation?.reviewerStatuses(author: author) ?? []
    }

    /// Everyone asked to review, in GitHub's order, then everyone else who has reviewed, each
    /// once. Someone asked again after reviewing shows as asked, as on github.com. The author's
    /// own reviews, which are their replies to threads, are left out, as is a review not yet
    /// submitted.
    public func reviewerStatuses(author: String?) -> [ReviewerStatus] {
        var statuses = reviewRequests.map { ReviewerStatus(reviewer: $0, state: .requested) }
        var shown = Set(statuses.map(\.id))
        for review in latestReviews where review.reviewer.login != author && !shown.contains(review.reviewer.id) {
            guard let state = ReviewerStatus.State(review.state) else { continue }
            statuses.append(ReviewerStatus(reviewer: review.reviewer, state: state))
            shown.insert(review.reviewer.id)
        }
        return statuses
    }
}

private extension ReviewerStatus.State {
    /// Nil for a review not yet submitted.
    init?(_ state: ReviewState) {
        switch state {
        case .approved: self = .approved
        case .changesRequested: self = .changesRequested
        case .commented, .unknown: self = .commented
        case .dismissed: self = .dismissed
        case .pending: return nil
        }
    }
}
