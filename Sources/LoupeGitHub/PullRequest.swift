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
            reviewThreadCount: node.reviewThreads?.totalCount,
            requestedReviewers: node.reviewRequests?.nodes.map(\.reviewer),
            stackId: node.stackEntry?.stack?.id,
            stackPosition: node.stackEntry?.position,
            stackParentId: node.baseRef?.associatedPullRequests.nodes.first?.id
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
        /// Only when looked up by id or number.
        let commitCount: Count?
        let comments: Count?
        let reviewThreads: Count?
        let reviewRequests: Connection<NodesResponse.ReviewRequest>?
        let requestEvents: Connection<NodesResponse.RequestEvent>?
        let latestOpinionatedReviews: Connection<NodesResponse.Verdict>?
        /// Null when the PR isn't in a GitHub stack.
        let stackEntry: StackEntry?
        /// Null when the base branch has been deleted.
        let baseRef: BaseRef?
        let viewerLatestReview: NodesResponse.LatestReview?
        let recentCommits: Connection<NodesResponse.RecentCommit>?
        let forcePushes: Connection<NodesResponse.ForcePush>?
    }

    struct StackEntry: Decodable {
        let position: Int
        let stack: Stack?

        struct Stack: Decodable { let id: String }
    }

    /// The open PRs whose head is this PR's base branch.
    struct BaseRef: Decodable {
        let associatedPullRequests: Connection<Identified>
    }

    struct Identified: Decodable { let id: String }

    struct Login: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Connection<Element: Decodable>: Decodable { let nodes: [Element] }
    struct Count: Decodable { let totalCount: Int }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable { let state: CheckState }
}

/// A PR as looked up by id or number, with who its review waits on and its latest requests
/// for review, which say which of the start screen's lists it belongs in.
public struct PullRequestLookup: Sendable, Equatable {
    public let pullRequest: PullRequestSummary
    public let reviewRequests: ReviewRequests

    init(_ node: SearchPageResponse.PullRequestNode) {
        pullRequest = PullRequestSummary(node)
        reviewRequests = ReviewRequests(
            state: node.state,
            requests: node.reviewRequests?.nodes ?? [],
            events: node.requestEvents?.nodes ?? [],
            verdicts: node.latestOpinionatedReviews?.nodes ?? [],
            viewerLatestReview: node.viewerLatestReview,
            commits: node.recentCommits?.nodes ?? [],
            forcePushes: node.forcePushes?.nodes ?? []
        )
    }
}

extension ReviewRequests {
    init(_ node: NodesResponse.PullRequestNode) {
        self.init(
            state: node.state, requests: node.reviewRequests.nodes, events: node.requestEvents.nodes, verdicts: node.latestOpinionatedReviews.nodes,
            viewerLatestReview: node.viewerLatestReview, commits: node.recentCommits.nodes, forcePushes: node.forcePushes.nodes
        )
    }

    init(
        state: PullRequestState,
        requests: [NodesResponse.ReviewRequest],
        events: [NodesResponse.RequestEvent],
        verdicts: [NodesResponse.Verdict],
        viewerLatestReview: NodesResponse.LatestReview?,
        commits: [NodesResponse.RecentCommit],
        forcePushes: [NodesResponse.ForcePush]
    ) {
        self.init(
            state: state,
            reviewers: requests.map(\.reviewer),
            events: events.map { ReviewRequestEvent(reviewer: $0.requestedReviewer?.reviewer ?? .other, createdAt: $0.createdAt) },
            verdicts: verdicts.compactMap { verdict in
                verdict.author.map { ReviewVerdict(login: $0.login, state: verdict.state, submittedAt: verdict.submittedAt, commitOid: verdict.commit?.oid) }
            },
            viewerLatestReview: viewerLatestReview.flatMap { $0.since(commits: commits, forcePushes: forcePushes) }
        )
    }
}

struct ViewerResponse: Decodable {
    let viewer: SearchPageResponse.Login
}

struct PullRequestNodesResponse: Decodable {
    /// Null where an id couldn't be resolved.
    let nodes: [SearchPageResponse.PullRequestNode?]
}

struct PullRequestByNumberResponse: Decodable {
    /// Null where the repo can't be found or the viewer can't see it.
    let repository: Repository?

    struct Repository: Decodable {
        /// Null where the repo has no PR with that number.
        let pullRequest: SearchPageResponse.PullRequestNode?
    }
}

struct NodesResponse: Decodable {
    /// Null where an id couldn't be resolved.
    let nodes: [PullRequestNode?]

    struct PullRequestNode: Decodable {
        let id: String
        let state: PullRequestState
        let reviewRequests: SearchPageResponse.Connection<ReviewRequest>
        let requestEvents: SearchPageResponse.Connection<RequestEvent>
        let latestOpinionatedReviews: SearchPageResponse.Connection<Verdict>
        let viewerLatestReview: LatestReview?
        let recentCommits: SearchPageResponse.Connection<RecentCommit>
        let forcePushes: SearchPageResponse.Connection<ForcePush>
    }

    /// The viewer's latest review, of any kind.
    struct LatestReview: Decodable {
        let state: ReviewState
        let submittedAt: Date?
        /// Null where its commit is gone from the repo.
        let commit: Verdict.Commit?

        /// What's happened since, from the PR's latest commits, oldest first, and force-pushes.
        /// Nil for a review not yet submitted.
        func since(commits: [RecentCommit], forcePushes: [ForcePush]) -> ViewerLatestReview? {
            guard state != .pending else { return nil }
            let reviewed = commit.flatMap { commit in commits.lastIndex { $0.commit.oid == commit.oid } }
            let pushedSince = forcePushes.map(\.createdAt).filter { pushed in submittedAt.map { pushed > $0 } ?? false }
            return ViewerLatestReview(
                state: state,
                submittedAt: submittedAt,
                commitOid: commit?.oid,
                commitsSince: reviewed.map { commits.count - 1 - $0 },
                lastCommittedAt: commits.last?.commit.committedDate,
                forcePushedAt: pushedSince.max()
            )
        }
    }

    struct RecentCommit: Decodable {
        let commit: Commit

        struct Commit: Decodable {
            let oid: String
            let committedDate: Date?
        }
    }

    struct ForcePush: Decodable {
        let createdAt: Date
    }

    struct Verdict: Decodable {
        let state: ReviewState
        /// Null when the reviewer's account has been deleted.
        let author: SearchPageResponse.Login?
        let submittedAt: Date?
        /// The head it was given on; null where its commit is gone from the repo.
        let commit: Commit?

        struct Commit: Decodable { let oid: String }
    }

    struct ReviewRequest: Decodable {
        /// Null when the requested account has been deleted.
        let requestedReviewer: Reviewer?

        var reviewer: RequestedReviewer {
            requestedReviewer?.reviewer ?? .other
        }
    }

    struct RequestEvent: Decodable {
        let createdAt: Date
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
