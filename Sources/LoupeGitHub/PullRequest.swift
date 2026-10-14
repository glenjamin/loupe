import Foundation
import LoupeModel

extension PullRequestSummary {
    init(_ node: SearchPageResponse.PullRequestNode) {
        self.init(
            id: node.id,
            repository: node.repository.nameWithOwner,
            number: node.number,
            title: node.title,
            url: node.url,
            author: node.author?.login,
            isDraft: node.isDraft,
            state: node.state,
            mergedAt: node.mergedAt,
            closedAt: node.closedAt,
            reviewDecision: node.reviewDecision,
            checks: node.commits.nodes.first?.commit.statusCheckRollup?.state,
            updatedAt: node.updatedAt,
            headRefName: node.headRefName,
            baseRefName: node.baseRefName,
            headRefOid: node.headRefOid,
            baseRefOid: node.baseRefOid,
            commitCount: node.commitCount?.totalCount,
            commentCount: node.comments?.totalCount,
            reviewThreadCount: node.reviewThreads?.totalCount
        )
    }
}

struct SearchPageResponse: Decodable {
    let search: Search

    struct Search: Decodable {
        let pageInfo: PageInfo
        let nodes: [PullRequestNode]
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct PullRequestNode: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let isDraft: Bool
        let state: PullRequestState
        let mergedAt: Date?
        let closedAt: Date?
        let updatedAt: Date
        let reviewDecision: ReviewDecision?
        let headRefName: String
        let baseRefName: String
        let headRefOid: String
        let baseRefOid: String
        let author: Login?
        let repository: Repository
        let commits: Connection<CommitNode>
        /// Only when looked up by id.
        let commitCount: Count?
        let comments: Count?
        let reviewThreads: Count?
    }

    struct Login: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Connection<Element: Decodable>: Decodable { let nodes: [Element] }
    struct Count: Decodable { let totalCount: Int }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable { let state: CheckState }
}

extension ReviewRequests {
    init(_ node: NodesResponse.PullRequestNode) {
        self.init(state: node.state, reviewers: node.reviewRequests.nodes.map { $0.requestedReviewer?.reviewer ?? .other })
    }
}

struct ViewerResponse: Decodable {
    let viewer: SearchPageResponse.Login
}

struct PullRequestNodesResponse: Decodable {
    /// Null where an id couldn't be resolved.
    let nodes: [SearchPageResponse.PullRequestNode?]
}

struct NodesResponse: Decodable {
    /// Null where an id couldn't be resolved.
    let nodes: [PullRequestNode?]

    struct PullRequestNode: Decodable {
        let id: String
        let state: PullRequestState
        let reviewRequests: SearchPageResponse.Connection<ReviewRequest>
    }

    struct ReviewRequest: Decodable {
        /// Null when the requested account has been deleted.
        let requestedReviewer: Reviewer?
    }

    struct Reviewer: Decodable {
        let reviewer: RequestedReviewer

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reviewer = switch try container.decode(String.self, forKey: .typename) {
            case "User": .user(login: try container.decode(String.self, forKey: .login))
            case "Team": .team(slug: try container.decode(String.self, forKey: .slug))
            default: .other
            }
        }

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case login
            case slug
        }
    }
}
