import Foundation

/// One PR as the start screen lists it.
public struct PullRequestSummary: Sendable, Hashable, Identifiable {
    /// GitHub's GraphQL node id, which survives repo renames and transfers.
    public let id: String
    /// `owner/name`.
    public let repository: String
    public let number: Int
    public let title: String
    public let url: URL
    /// Nil when the author's account has been deleted.
    public let author: String?
    public let isDraft: Bool
    public let state: PullRequestState
    public let mergedAt: Date?
    public let closedAt: Date?
    /// Nil when the base branch doesn't require reviews.
    public let reviewDecision: ReviewDecision?
    /// Nil when the head commit has no statuses or check runs.
    public let checks: CheckState?
    /// The head commit's statuses and check runs one by one. Empty until they've been looked
    /// up, as searches don't fetch them.
    public let checkContexts: [CheckContext]
    /// Nil until looked up by id, as asking the searches for it takes them past GitHub's time
    /// limit. `.unknown` while GitHub is still working it out.
    public let mergeable: MergeableState?
    /// GitHub's verdict on whether the PR can be merged now, as its merge box shows it. Nil
    /// until looked up by id, as `mergeable` is.
    public let mergeStateStatus: MergeStateStatus?
    public let updatedAt: Date
    public let headRefName: String
    public let baseRefName: String
    /// The head and base commits. Nil on rows stored before these were fetched, until the
    /// list's next full load.
    public let headRefOid: String?
    public let baseRefOid: String?
    /// How many commits, conversation comments and review threads the PR has. Nil until the PR
    /// is looked up by id, as searches don't fetch them.
    public let commitCount: Int?
    public let commentCount: Int?
    public let reviewThreadCount: Int?
    /// When the viewer was last asked to review, as the to-review list's check found it. Nil
    /// until checked, or when GitHub's timeline had no request of the viewer to show.
    public let reviewRequestedAt: Date?
    /// Who the PR's review waits on, in GitHub's order. Nil until looked up by id, as asking the
    /// searches for it takes them past GitHub's time limit.
    public var requestedReviewers: [RequestedReviewer]?
    /// The state of the viewer's latest approval or request for changes, dismissed or not, as
    /// the to-review list's check found it. Nil until checked, or when they've given neither.
    public let viewerReview: ReviewState?

    public init(
        id: String,
        repository: String,
        number: Int,
        title: String,
        url: URL,
        author: String?,
        isDraft: Bool,
        state: PullRequestState = .open,
        mergedAt: Date? = nil,
        closedAt: Date? = nil,
        reviewDecision: ReviewDecision?,
        checks: CheckState?,
        checkContexts: [CheckContext] = [],
        mergeable: MergeableState? = nil,
        mergeStateStatus: MergeStateStatus? = nil,
        updatedAt: Date,
        headRefName: String,
        baseRefName: String,
        headRefOid: String? = nil,
        baseRefOid: String? = nil,
        commitCount: Int? = nil,
        commentCount: Int? = nil,
        reviewThreadCount: Int? = nil,
        reviewRequestedAt: Date? = nil,
        requestedReviewers: [RequestedReviewer]? = nil,
        viewerReview: ReviewState? = nil
    ) {
        self.id = id
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.isDraft = isDraft
        self.state = state
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.checkContexts = checkContexts
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.updatedAt = updatedAt
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.headRefOid = headRefOid
        self.baseRefOid = baseRefOid
        self.commitCount = commitCount
        self.commentCount = commentCount
        self.reviewThreadCount = reviewThreadCount
        self.reviewRequestedAt = reviewRequestedAt
        self.requestedReviewers = requestedReviewers
        self.viewerReview = viewerReview
    }

    /// The approval or request for changes `login` has made and still stands by, while they
    /// aren't asked to review again: the PR then waits on its author or a merge rather than on
    /// them. A team's request doesn't count against it, as the viewer may not be in the team.
    public func standingVerdict(of login: String) -> ReviewState? {
        guard let viewerReview, viewerReview.isVerdict else { return nil }
        let reRequested = (requestedReviewers ?? []).contains { $0.isUser(login) }
        return reRequested ? nil : viewerReview
    }
}

/// What a PR's lookup by id says of its head commit: its checks, overall and one by one,
/// whether it merges cleanly, whether it can be merged now and its review decision.
public struct PullRequestStatus: Sendable, Equatable {
    /// Nil when the head commit has no statuses or check runs.
    public let checks: CheckState?
    public let checkContexts: [CheckContext]
    public let mergeable: MergeableState
    public let mergeStateStatus: MergeStateStatus
    /// Nil when the base branch doesn't require reviews.
    public let reviewDecision: ReviewDecision?

    public init(checks: CheckState?, checkContexts: [CheckContext], mergeable: MergeableState, mergeStateStatus: MergeStateStatus, reviewDecision: ReviewDecision?) {
        self.checks = checks
        self.checkContexts = checkContexts
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.reviewDecision = reviewDecision
    }
}

/// The start screen's two searches.
public enum PullRequestList: String, Sendable, CaseIterable {
    /// The signed-in user's PRs, drafts included.
    case mine
    /// PRs awaiting the signed-in user's review, and those they've approved or asked changes of
    /// until merged or closed.
    case toReview
}

public enum PullRequestState: String, Sendable, LenientEnum {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
    case unknown
}

/// A PR's state, whose review it's currently waiting on, its latest requests for review and
/// each reviewer's latest verdict.
public struct ReviewRequests: Sendable, Equatable {
    public let state: PullRequestState
    public let reviewers: [RequestedReviewer]
    /// The latest requests from the PR's timeline, re-requests included, whether or not still
    /// pending.
    public let events: [ReviewRequestEvent]
    /// Each reviewer's latest approval or request for changes, as dismissed if it was.
    public let verdicts: [ReviewVerdict]

    public init(state: PullRequestState, reviewers: [RequestedReviewer], events: [ReviewRequestEvent] = [], verdicts: [ReviewVerdict] = []) {
        self.state = state
        self.reviewers = reviewers
        self.events = events
        self.verdicts = verdicts
    }

    /// The state of `login`'s latest approval or request for changes, nil if they've given
    /// neither.
    public func latestVerdict(by login: String) -> ReviewState? {
        verdicts.last { $0.login.caseInsensitiveCompare(login) == .orderedSame }?.state
    }

    /// Whether the PR belongs in `login`'s To review: open, and either waiting on their review
    /// or holding their approval or request for changes, so they can see it through to merge.
    public func belongsInToReview(of login: String) -> Bool {
        awaitReview(from: login) || (state == .open && latestVerdict(by: login)?.isVerdict == true)
    }

    /// When `login` was last asked to review, as far as the latest requests go back. A request
    /// of any team counts, for the same reason as in `awaitReview(from:)`.
    public func lastRequested(of login: String) -> Date? {
        events.filter { $0.reviewer.mayBe(login) }.map(\.createdAt).max()
    }

    /// Whether the PR is open and still waiting on `login`. A request to any team counts, as
    /// GitHub's `review-requested:@me` matches the viewer's teams and team membership isn't
    /// known here.
    public func awaitReview(from login: String) -> Bool {
        state == .open && reviewers.contains { $0.mayBe(login) }
    }
}

/// A reviewer's latest approval or request for changes on a PR.
public struct ReviewVerdict: Sendable, Equatable {
    public let login: String
    public let state: ReviewState

    public init(login: String, state: ReviewState) {
        self.login = login
        self.state = state
    }
}

/// One request for review, as GitHub's timeline records it.
public struct ReviewRequestEvent: Sendable, Equatable {
    public let reviewer: RequestedReviewer
    public let createdAt: Date

    public init(reviewer: RequestedReviewer, createdAt: Date) {
        self.reviewer = reviewer
        self.createdAt = createdAt
    }
}

public enum RequestedReviewer: Sendable, Hashable {
    case user(login: String)
    case team(slug: String)
    /// A bot, mannequin or deleted account: never the viewer.
    case other

    /// The request a review request from here makes: a team by its slug, as GitHub's own
    /// requested reviewers name it.
    public init(_ reviewer: Reviewer) {
        switch reviewer.kind {
        case .user: self = .user(login: reviewer.login)
        case .team: self = .team(slug: String(reviewer.login.split(separator: "/").last ?? ""))
        case .bot: self = .other
        }
    }

    /// A user's login or a team's slug; nil for anything else, which isn't named.
    public var name: String? {
        switch self {
        case let .user(login): login
        case let .team(slug): slug
        case .other: nil
        }
    }

    /// Whether this is the user `login`, not a team they may be in.
    func isUser(_ login: String) -> Bool {
        if case let .user(requested) = self { requested.caseInsensitiveCompare(login) == .orderedSame } else { false }
    }

    /// Whether this could be `login`: that user, or any team, as team membership isn't known.
    func mayBe(_ login: String) -> Bool {
        switch self {
        case let .user(requested): requested.caseInsensitiveCompare(login) == .orderedSame
        case .team: true
        case .other: false
        }
    }
}

public enum ReviewDecision: String, Sendable, LenientEnum {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
    case unknown
}

public enum CheckState: String, Sendable, LenientEnum {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"
    case unknown
}

/// Whether a PR's head merges into its base without conflicts. GitHub works it out lazily, in
/// the background, and answers `UNKNOWN` until it has.
public enum MergeableState: String, Sendable, LenientEnum {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"
}

/// Whether a PR can be merged now and, if not, broadly why: GitHub's own merge-box verdict,
/// which weighs branch protection, required checks and reviews. Worked out lazily, like
/// `mergeable`. GitHub no longer answers `DRAFT`, saying `BLOCKED` for a draft.
public enum MergeStateStatus: String, Sendable, LenientEnum {
    case clean = "CLEAN"
    /// Mergeable, with pre-receive hooks to pass.
    case hasHooks = "HAS_HOOKS"
    /// Mergeable, though checks that aren't required are failing.
    case unstable = "UNSTABLE"
    case blocked = "BLOCKED"
    /// The head is out of date with its base, which branch protection requires it not to be.
    case behind = "BEHIND"
    /// Conflicts with its base.
    case dirty = "DIRTY"
    case draft = "DRAFT"
    case unknown = "UNKNOWN"
}

/// A GitHub enum that maps values GitHub adds later to `.unknown` rather than failing to decode
/// or load.
public protocol LenientEnum: Decodable, Hashable, RawRepresentable<String> {
    static var unknown: Self { get }
}

extension LenientEnum {
    public init(from decoder: any Decoder) throws {
        self.init(lenientRawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public init(lenientRawValue: String) {
        self = Self(rawValue: lenientRawValue) ?? .unknown
    }
}
