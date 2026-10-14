import Foundation

public struct PullRequestLists: Sendable, Equatable {
    public let mine: PullRequestPage
    public let toReview: PullRequestPage
}

/// The first page of a search, newest first. `totalCount` can exceed `pullRequests.count`.
public struct PullRequestPage: Sendable, Equatable {
    public let pullRequests: [PullRequestSummary]
    public let totalCount: Int
}

public struct PullRequestSummary: Sendable, Hashable, Identifiable {
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

    public var id: URL { url }
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

/// Decodes a GraphQL enum, mapping values GitHub adds later to `.unknown` rather than failing
/// the whole response.
public protocol LenientEnum: Decodable, Hashable, RawRepresentable<String> {
    static var unknown: Self { get }
}

extension LenientEnum {
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

extension PullRequestPage {
    init(_ search: SearchResponse) {
        pullRequests = search.nodes
            .map(PullRequestSummary.init)
            .sorted { $0.updatedAt > $1.updatedAt }
        totalCount = search.issueCount
    }
}

extension PullRequestSummary {
    init(_ node: SearchResponse.Node) {
        repository = node.repository.nameWithOwner
        number = node.number
        title = node.title
        url = node.url
        author = node.author?.login
        isDraft = node.isDraft
        reviewDecision = node.reviewDecision
        checks = node.commits.nodes.first?.commit.statusCheckRollup?.state
        updatedAt = node.updatedAt
        headRefName = node.headRefName
        baseRefName = node.baseRefName
    }
}

struct PullRequestListsResponse: Decodable {
    let mine: SearchResponse
    let toReview: SearchResponse
}

struct SearchResponse: Decodable {
    let issueCount: Int
    let nodes: [Node]

    struct Node: Decodable {
        let number: Int
        let title: String
        let url: URL
        let isDraft: Bool
        let updatedAt: Date
        let reviewDecision: ReviewDecision?
        let headRefName: String
        let baseRefName: String
        let author: Login?
        let repository: Repository
        let commits: Connection<CommitNode>
    }

    struct Login: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Connection<Element: Decodable>: Decodable { let nodes: [Element] }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable { let state: CheckState }
}
