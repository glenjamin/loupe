import Foundation
import LoupeModel

extension GitHubClient {
    /// The PR's description, timeline, review threads and head commit's checks, following the
    /// timeline's pages to the end.
    public func conversation(ofPullRequest id: String) async throws -> Conversation {
        let first: ConversationResponse = try await query(Self.conversationQuery, variables: ConversationVariables(id: id, after: nil))
        guard let pullRequest = first.node else { throw GitHubError.graphQL(["Pull request \(id) not found"]) }
        var nodes = pullRequest.timelineItems.nodes
        var page = pullRequest.timelineItems.pageInfo
        while page.hasNextPage, let cursor = page.endCursor {
            let next: TimelinePageResponse = try await query(Self.timelinePageQuery, variables: ConversationVariables(id: id, after: cursor))
            guard let timeline = next.node?.timelineItems else { throw GitHubError.graphQL(["Pull request \(id) not found"]) }
            nodes += timeline.nodes
            page = timeline.pageInfo
        }
        return Conversation(
            author: pullRequest.author?.participant,
            createdAt: pullRequest.createdAt,
            bodyHTML: pullRequest.bodyHTML,
            items: nodes.compactMap(\.timelineItem),
            threads: pullRequest.reviewThreads.nodes.map(\.thread),
            checks: pullRequest.commits.nodes.first?.commit.statusCheckRollup?.contexts.nodes.compactMap(\.check) ?? []
        )
    }

    static let conversationQuery = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on PullRequest {
              bodyHTML
              createdAt
              author { login avatarUrl }
              timelineItems(first: 100, after: $after, itemTypes: \(timelineItemTypes)) { ...TimelinePage }
              reviewThreads(first: 100) {
                nodes { id isResolved isOutdated path line comments(first: 100) { nodes { id bodyHTML createdAt isMinimized author { login avatarUrl } } } }
              }
              commits(last: 1) {
                nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { \(checkContextFields) } } } } }
              }
            }
          }
        }
        """ + timelinePageFragment

    static let timelinePageQuery = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on PullRequest {
              timelineItems(first: 100, after: $after, itemTypes: \(timelineItemTypes)) { ...TimelinePage }
            }
          }
        }
        """ + timelinePageFragment

    static let timelineItemTypes = "[ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, REVIEW_REQUESTED_EVENT, READY_FOR_REVIEW_EVENT]"

    /// A review here holds only the comments made with it; replies made later are in reply-only
    /// reviews the timeline leaves out, so they come from the review threads.
    static let timelinePageFragment = """

        fragment TimelinePage on PullRequestTimelineItemsConnection {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on IssueComment { id bodyHTML createdAt isMinimized author { login avatarUrl } }
            ... on PullRequestReview {
              id state bodyHTML createdAt submittedAt author { login avatarUrl }
              comments(first: 50) { nodes { id bodyHTML path line originalLine diffHunk outdated isMinimized replyTo { id } } }
            }
            ... on PullRequestCommit { id commit { oid messageHeadline committedDate author { name user { login avatarUrl } } } }
            ... on HeadRefForcePushedEvent { id createdAt actor { login avatarUrl } beforeCommit { oid } afterCommit { oid } }
            ... on MergedEvent { id createdAt actor { login avatarUrl } commit { oid } mergeRefName }
            ... on ClosedEvent { id createdAt actor { login avatarUrl } }
            ... on ReopenedEvent { id createdAt actor { login avatarUrl } }
            ... on ReviewRequestedEvent { id createdAt actor { login avatarUrl } requestedReviewer { __typename ... on User { login } ... on Team { slug } ... on Bot { login } ... on Mannequin { login } } }
            ... on ReadyForReviewEvent { id createdAt actor { login avatarUrl } }
          }
        }
        """
}

private struct ConversationVariables: Encodable, Sendable {
    let id: String
    let after: String?

    // `after` is sent as null on the first page rather than left out.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(after, forKey: .after)
    }

    enum CodingKeys: CodingKey { case id, after }
}

private struct ConversationResponse: Decodable {
    let node: PullRequest?

    struct PullRequest: Decodable {
        let bodyHTML: String
        let createdAt: Date
        let author: Author?
        let timelineItems: Timeline
        let reviewThreads: Connection<Thread>
        let commits: Connection<CommitNode>
    }

    struct Thread: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let path: String
        let line: Int?
        let comments: Connection<Comment>

        var thread: ReviewThread {
            ReviewThread(id: id, isResolved: isResolved, isOutdated: isOutdated, path: path, line: line, comments: comments.nodes.map {
                ThreadComment(id: $0.id, author: $0.author?.participant, createdAt: $0.createdAt, bodyHTML: $0.bodyHTML, isMinimized: $0.isMinimized)
            })
        }
    }

    struct Comment: Decodable {
        let id: String
        let bodyHTML: String
        let createdAt: Date
        let isMinimized: Bool
        let author: Author?
    }

    struct CommitNode: Decodable {
        let commit: Commit
    }

    struct Commit: Decodable {
        let statusCheckRollup: Rollup?
    }

    struct Rollup: Decodable {
        let contexts: Connection<CheckContextNode>
    }
}

private struct TimelinePageResponse: Decodable {
    let node: Node?

    struct Node: Decodable {
        let timelineItems: Timeline?
    }
}

private struct Timeline: Decodable {
    let pageInfo: PageInfo
    let nodes: [TimelineNode]

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

private struct Connection<Node: Decodable>: Decodable {
    let nodes: [Node]
}

private struct Author: Decodable {
    let login: String
    let avatarUrl: String?

    var participant: Participant {
        Participant(login: login, avatarURL: avatarUrl)
    }
}

/// Any of the timeline's kinds of item; which fields are set depends on `__typename`.
private struct TimelineNode: Decodable {
    let __typename: String
    let id: String?
    let bodyHTML: String?
    let createdAt: Date?
    let submittedAt: Date?
    let isMinimized: Bool?
    let author: Author?
    let actor: Author?
    let state: ReviewState?
    let comments: Connection<ReviewCommentNode>?
    let commit: Commit?
    let beforeCommit: Oid?
    let afterCommit: Oid?
    let mergeRefName: String?
    let requestedReviewer: Reviewer?

    struct Commit: Decodable {
        let oid: String
        let messageHeadline: String?
        let committedDate: Date?
        let author: CommitAuthor?
    }

    struct CommitAuthor: Decodable {
        let name: String?
        let user: Author?
    }

    struct Oid: Decodable {
        let oid: String
    }

    struct Reviewer: Decodable {
        let login: String?
        let slug: String?
    }

    struct ReviewCommentNode: Decodable {
        let id: String
        let bodyHTML: String
        let path: String
        let line: Int?
        let originalLine: Int?
        let diffHunk: String
        let outdated: Bool
        let isMinimized: Bool
        let replyTo: Oid?

        struct Oid: Decodable { let id: String }
    }

    /// Nil for a kind not asked for, or one missing what it needs.
    var timelineItem: TimelineItem? {
        guard let id else { return nil }
        switch __typename {
        case "IssueComment":
            guard let createdAt else { return nil }
            return TimelineItem(id: id, date: createdAt, actor: author?.participant, event: .comment(bodyHTML: bodyHTML ?? "", isMinimized: isMinimized ?? false))
        case "PullRequestReview":
            // A pending review has no submission time yet.
            guard let date = submittedAt ?? createdAt else { return nil }
            let comments = (comments?.nodes ?? []).map {
                ReviewComment(id: $0.id, bodyHTML: $0.bodyHTML, path: $0.path, line: $0.line, originalLine: $0.originalLine, diffHunk: $0.diffHunk, isOutdated: $0.outdated, isMinimized: $0.isMinimized, replyTo: $0.replyTo?.id)
            }
            return TimelineItem(id: id, date: date, actor: author?.participant, event: .review(state: state ?? .unknown, bodyHTML: bodyHTML ?? "", comments: comments))
        case "PullRequestCommit":
            guard let commit, let date = commit.committedDate else { return nil }
            let author = commit.author.flatMap { $0.user?.participant ?? $0.name.map { Participant(login: $0, avatarURL: nil) } }
            return TimelineItem(id: id, date: date, actor: author, event: .commit(oid: commit.oid, headline: commit.messageHeadline ?? ""))
        default:
            guard let createdAt, let event else { return nil }
            return TimelineItem(id: id, date: createdAt, actor: actor?.participant, event: event)
        }
    }

    private var event: TimelineEvent? {
        switch __typename {
        case "HeadRefForcePushedEvent": .forcePushed(before: beforeCommit?.oid, after: afterCommit?.oid)
        case "MergedEvent": .merged(commit: commit?.oid, into: mergeRefName ?? "")
        case "ClosedEvent": .closed
        case "ReopenedEvent": .reopened
        case "ReadyForReviewEvent": .readyForReview
        case "ReviewRequestedEvent": .reviewRequested(reviewer: requestedReviewer.flatMap { $0.login ?? $0.slug })
        default: nil
        }
    }
}
