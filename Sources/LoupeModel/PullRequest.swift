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
        updatedAt: Date,
        headRefName: String,
        baseRefName: String,
        headRefOid: String? = nil,
        baseRefOid: String? = nil,
        commitCount: Int? = nil,
        commentCount: Int? = nil,
        reviewThreadCount: Int? = nil
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
        self.updatedAt = updatedAt
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.headRefOid = headRefOid
        self.baseRefOid = baseRefOid
        self.commitCount = commitCount
        self.commentCount = commentCount
        self.reviewThreadCount = reviewThreadCount
    }
}

/// A PR's head commit's checks: the overall state and each status or check run.
public struct PullRequestChecks: Sendable, Equatable {
    /// Nil when the head commit has no statuses or check runs.
    public let state: CheckState?
    public let contexts: [CheckContext]

    public init(state: CheckState?, contexts: [CheckContext]) {
        self.state = state
        self.contexts = contexts
    }
}

/// The start screen's two searches.
public enum PullRequestList: String, Sendable, CaseIterable {
    /// The signed-in user's PRs, drafts included.
    case mine
    /// PRs awaiting the signed-in user's review.
    case toReview
}

public enum PullRequestState: String, Sendable, LenientEnum {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
    case unknown
}

/// A PR's state and whose review it's currently waiting on.
public struct ReviewRequests: Sendable, Equatable {
    public let state: PullRequestState
    public let reviewers: [RequestedReviewer]

    public init(state: PullRequestState, reviewers: [RequestedReviewer]) {
        self.state = state
        self.reviewers = reviewers
    }

    /// Whether the PR is open and still waiting on `login`. A request to any team counts, as
    /// GitHub's `review-requested:@me` matches the viewer's teams and team membership isn't
    /// known here.
    public func awaitReview(from login: String) -> Bool {
        state == .open && reviewers.contains { reviewer in
            switch reviewer {
            case let .user(requested): requested.caseInsensitiveCompare(login) == .orderedSame
            case .team: true
            case .other: false
            }
        }
    }
}

public enum RequestedReviewer: Sendable, Hashable {
    case user(login: String)
    case team(slug: String)
    /// A bot, mannequin or deleted account: never the viewer.
    case other
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
