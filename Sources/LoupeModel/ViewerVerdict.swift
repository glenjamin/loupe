import Foundation

/// The viewer's approval or request for changes on a PR: when, on which head, and how the PR
/// has moved on since, so they can tell at a glance whether it's still what they reviewed.
public struct ViewerVerdict: Sendable, Equatable {
    public enum Since: Sendable, Equatable {
        /// The head is still the commit the verdict was given on.
        case unchanged
        /// The head has this many commits on top of that commit.
        case commits(Int)
        /// The head has moved on in a way that isn't counted: force-pushed away from the commit,
        /// or not yet looked at.
        case changed
    }

    /// `.approved` or `.changesRequested`.
    public let state: ReviewState
    /// The head it was given on, nil when that isn't known.
    public let commitOid: String?
    public let submittedAt: Date?
    /// Nil when the head it was given on isn't known.
    public let since: Since?

    public init(state: ReviewState, commitOid: String?, submittedAt: Date?, since: Since?) {
        self.state = state
        self.commitOid = commitOid
        self.submittedAt = submittedAt
        self.since = since
    }

    /// Whether the PR's head is still exactly what the viewer gave their verdict on.
    public var isCurrent: Bool {
        since == .unchanged
    }
}

extension PullRequestSummary {
    /// The viewer's approval or request for changes as the to-review check last found it,
    /// against the head as stored. Commits since aren't counted here, as the row has no list of
    /// them.
    public var viewerVerdict: ViewerVerdict? {
        guard let viewerReview, viewerReview.isVerdict else { return nil }
        let since: ViewerVerdict.Since? = viewerReviewCommitOid.flatMap { reviewed in
            headRefOid.map { $0 == reviewed ? .unchanged : .changed }
        }
        return ViewerVerdict(state: viewerReview, commitOid: viewerReviewCommitOid, submittedAt: viewerReviewedAt, since: since)
    }
}
