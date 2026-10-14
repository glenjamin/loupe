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
    /// Nil when the base branch doesn't require reviews.
    public let reviewDecision: ReviewDecision?
    /// Nil when the head commit has no statuses or check runs.
    public let checks: CheckState?
    public let updatedAt: Date
    public let headRefName: String
    public let baseRefName: String

    public init(
        id: String,
        repository: String,
        number: Int,
        title: String,
        url: URL,
        author: String?,
        isDraft: Bool,
        reviewDecision: ReviewDecision?,
        checks: CheckState?,
        updatedAt: Date,
        headRefName: String,
        baseRefName: String
    ) {
        self.id = id
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.updatedAt = updatedAt
        self.headRefName = headRefName
        self.baseRefName = baseRefName
    }
}

/// The start screen's two searches.
public enum PullRequestList: String, Sendable, CaseIterable {
    /// The signed-in user's open PRs, drafts included.
    case mine
    /// Open PRs awaiting the signed-in user's review.
    case toReview
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
