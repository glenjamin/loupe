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
    /// What `login`'s reviews of the PR come to on its row, nil where they haven't reviewed it.
    /// A verdict outlasts a later comment, though the comment still counts as looking again.
    /// Anything pushed since counts as an update, as does asking the viewer by name to review
    /// again, which is the author saying to look again.
    public func viewerReviewMark(viewer login: String) -> ViewerReviewMark? {
        let verdict = viewerReview?.isVerdict == true ? viewerReview : nil
        let latest = viewerLatestReview ?? viewerReview.map { ViewerLatestReview(state: $0, submittedAt: viewerReviewedAt, commitOid: viewerReviewCommitOid) }
        guard let latest, let kind = verdict.map(ViewerReviewMark.Kind.init(verdict:)) ?? ViewerReviewMark.Kind(latest: latest.state) else { return nil }
        var updates: [ViewerReviewMark.Update] = []
        if let headRefOid, let reviewed = latest.commitOid, headRefOid != reviewed {
            updates.append(latest.update)
        }
        let requestedByName = (requestedReviewers ?? []).contains { $0.isUser(login) }
        if requestedByName, let requestedAt = reviewRequestedAt, let reviewedAt = latest.submittedAt, requestedAt > reviewedAt {
            updates.append(.reRequested(at: requestedAt))
        }
        return ViewerReviewMark(kind: kind, givenAt: verdict == nil ? latest.submittedAt : viewerReviewedAt, reviewedAt: latest.submittedAt, updates: updates)
    }
}

/// The viewer's latest submitted review of a PR, of any kind, and how the PR's branch has moved
/// on from it, as GitHub said when the PR was last checked.
public struct ViewerLatestReview: Sendable, Hashable {
    public let state: ReviewState
    public let submittedAt: Date?
    /// The head it was made on; nil where that commit is gone from the repo.
    public let commitOid: String?
    /// How many of the PR's commits come after that one, nil where it isn't among its latest.
    public let commitsSince: Int?
    /// When the PR's newest commit was committed.
    public let lastCommittedAt: Date?
    /// When the branch was last force-pushed after the review, nil if it hasn't been.
    public let forcePushedAt: Date?

    public init(state: ReviewState, submittedAt: Date?, commitOid: String?, commitsSince: Int? = nil, lastCommittedAt: Date? = nil, forcePushedAt: Date? = nil) {
        self.state = state
        self.submittedAt = submittedAt
        self.commitOid = commitOid
        self.commitsSince = commitsSince
        self.lastCommittedAt = lastCommittedAt
        self.forcePushedAt = forcePushedAt
    }
}

/// What a To review row says of the viewer's reviews of the PR: their verdict, or that they
/// commented, and whether it's been updated since they last reviewed, so what's worth another
/// look stands out from what's still as they left it.
public struct ViewerReviewMark: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case approved
        case changesRequested
        /// Their latest review only commented, and they've given no verdict.
        case commented
        /// Their verdict was dismissed, and they haven't reviewed since.
        case dismissed
    }

    /// What's happened since the viewer's latest review.
    public enum Update: Sendable, Equatable {
        /// This many commits pushed on top of the reviewed one, the newest committed then.
        case commits(Int, lastCommittedAt: Date?)
        /// Force-pushed away from what was reviewed, most recently then.
        case forcePushed(at: Date)
        /// The head has moved on in a way that wasn't counted.
        case changed
        /// The viewer was asked to review it again then.
        case reRequested(at: Date)
    }

    public let kind: Kind
    /// When the review the kind names was given.
    public let givenAt: Date?
    /// When the viewer last reviewed it, of any kind, which updates are counted from.
    public let reviewedAt: Date?
    /// Empty while the PR is as the viewer last reviewed it.
    public let updates: [Update]

    public init(kind: Kind, givenAt: Date?, reviewedAt: Date?, updates: [Update]) {
        self.kind = kind
        self.givenAt = givenAt
        self.reviewedAt = reviewedAt
        self.updates = updates
    }

    public var isUpdated: Bool {
        !updates.isEmpty
    }
}

private extension ViewerLatestReview {
    /// How the head got away from the reviewed commit, as far as the last check could tell.
    var update: ViewerReviewMark.Update {
        if let forcePushedAt { return .forcePushed(at: forcePushedAt) }
        if let commitsSince, commitsSince > 0 { return .commits(commitsSince, lastCommittedAt: lastCommittedAt) }
        return .changed
    }
}

private extension ViewerReviewMark.Kind {
    init(verdict: ReviewState) {
        self = verdict == .approved ? .approved : .changesRequested
    }

    /// Nil for a review not yet submitted.
    init?(latest state: ReviewState) {
        switch state {
        case .approved: self = .approved
        case .changesRequested: self = .changesRequested
        case .dismissed: self = .dismissed
        case .commented, .unknown: self = .commented
        case .pending: return nil
        }
    }
}
