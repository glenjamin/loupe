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
            reviewDecision: node.reviewDecision,
            checks: node.commits.nodes.first?.commit.statusCheckRollup?.state,
            updatedAt: node.updatedAt,
            headRefName: node.headRefName,
            baseRefName: node.baseRefName
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
