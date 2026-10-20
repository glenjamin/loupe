import Foundation
import LoupeModel

extension GitHubClient {
    /// The PR's description, timeline, review threads, head commit's checks, reviewers and
    /// `viewer`'s pending review, following the timeline's pages to the end. With no `viewer`,
    /// the pending review is whichever GitHub shows, which is only ever the viewer's own.
    public func conversation(ofPullRequest id: String, viewer: String? = nil) async throws -> Conversation {
        let first: ConversationResponse = try await query(Self.conversationQuery, variables: FirstPageVariables(id: id, viewer: viewer))
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
            id: id,
            author: pullRequest.author?.participant,
            createdAt: pullRequest.createdAt,
            bodyHTML: pullRequest.bodyHTML,
            body: pullRequest.body,
            reactions: pullRequest.reactionGroups.shown,
            items: nodes.compactMap(\.timelineItem),
            threads: pullRequest.reviewThreads.nodes.map(\.thread),
            checks: pullRequest.commits.nodes.first?.commit.statusCheckRollup?.contexts.nodes.compactMap(\.check) ?? [],
            reviewRequests: pullRequest.reviewRequests.nodes.compactMap { $0.requestedReviewer?.reviewer },
            latestReviews: pullRequest.latestReviews.nodes.compactMap(\.latestReview),
            pendingReview: pullRequest.pendingReview.nodes.first?.pendingReview,
            viewerReview: pullRequest.viewerLatestReview?.viewerReview
        )
    }

    /// The PR's review threads and `viewer`'s pending review alone, as after a reply, a change
    /// to a thread or to the review, which is much cheaper than the whole conversation.
    public func reviewThreads(ofPullRequest id: String, viewer: String? = nil) async throws -> ReviewThreads {
        let response: ReviewThreadsResponse = try await query(Self.reviewThreadsQuery, variables: ReviewThreadsVariables(id: id, viewer: viewer))
        guard let node = response.node, let threads = node.reviewThreads, let pending = node.pendingReview else {
            throw GitHubError.graphQL(["Pull request \(id) not found"])
        }
        return ReviewThreads(threads: threads.nodes.map(\.thread), pendingReview: pending.nodes.first?.pendingReview)
    }

    static let reviewThreadsQuery = """
        query($id: ID!, $viewer: String) {
          node(id: $id) {
            ... on PullRequest {
              reviewThreads(first: 100) { nodes { ...ReviewThread } }
              \(pendingReviewField)
            }
          }
        }
        """ + reviewThreadFragment

    /// Only the viewer can see their pending review, and they have at most one per PR.
    static let pendingReviewField = "pendingReview: reviews(first: 1, states: [PENDING], author: $viewer) { nodes { id body comments { totalCount } } }"

    static let conversationQuery = """
        query($id: ID!, $after: String, $viewer: String) {
          node(id: $id) {
            ... on PullRequest {
              bodyHTML
              body
              createdAt
              author { login avatarUrl }
              \(reactionGroupsField)
              timelineItems(first: 100, after: $after, itemTypes: \(timelineItemTypes)) { ...TimelinePage }
              reviewThreads(first: 100) { nodes { ...ReviewThread } }
              commits(last: 1) {
                nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { \(checkContextFields) } } } } }
              }
              reviewRequests(first: 20) { nodes { requestedReviewer { ...Reviewer } } }
              latestReviews(first: 50) { nodes { state submittedAt author { ...Reviewer } } }
              viewerLatestReview { state submittedAt commit { oid } }
              \(pendingReviewField)
            }
          }
        }
        """ + timelinePageFragment + reviewerFragment + reviewThreadFragment

    /// A thread's anchoring, what the viewer may do with it, and its comments, each saying
    /// whether it's in the viewer's pending review and whether the viewer may edit or delete
    /// it. Only the
    /// first comment's diff hunk is asked for, as replies share it.
    static let reviewThreadFragment = """

        fragment ReviewThread on PullRequestReviewThread {
          id isResolved isOutdated path line startLine diffSide startDiffSide originalLine originalStartLine subjectType
          viewerCanReply viewerCanResolve viewerCanUnresolve
          resolvedBy { login }
          firstComment: comments(first: 1) { nodes { diffHunk } }
          comments(first: 100) { nodes { id databaseId bodyHTML createdAt isMinimized minimizedReason state viewerCanUpdate viewerCanDelete author { login avatarUrl } \(reactionGroupsField) } }
        }
        """

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

    /// Whoever can be asked to review, or has reviewed: a person, team or bot. A team's name is
    /// aliased as it can't be null where a user's can.
    static let reviewerFragment = """

        fragment Reviewer on Node {
          __typename
          ... on User { id login name avatarUrl }
          ... on Bot { id login avatarUrl }
          ... on Team { id teamName: name combinedSlug }
        }
        """

    /// A review here holds only the comments made with it; replies made later are in reply-only
    /// reviews the timeline leaves out, so they come from the review threads.
    static let timelinePageFragment = """

        fragment TimelinePage on PullRequestTimelineItemsConnection {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on IssueComment { id databaseId bodyHTML body createdAt updatedAt isMinimized viewerCanUpdate viewerCanDelete author { login avatarUrl } \(reactionGroupsField) }
            ... on PullRequestReview {
              id databaseId state bodyHTML createdAt submittedAt viewerCanUpdate author { login avatarUrl } \(reactionGroupsField)
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

/// The first page's, which also names whose pending review to fetch.
private struct FirstPageVariables: Encodable, Sendable {
    let id: String
    let viewer: String?

    // `after` and an unknown `viewer` are sent as null rather than left out.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeNil(forKey: .after)
        try container.encode(viewer, forKey: .viewer)
    }

    enum CodingKeys: CodingKey { case id, after, viewer }
}

/// The viewer's pending review, as `pendingReviewField` returns it.
private struct PendingReviewNode: Decodable {
    let id: String
    let body: String
    let comments: Count

    struct Count: Decodable { let totalCount: Int }

    var pendingReview: PendingReview {
        PendingReview(id: id, body: body, commentCount: comments.totalCount)
    }
}

private struct ConversationResponse: Decodable {
    let node: PullRequest?

    struct PullRequest: Decodable {
        let bodyHTML: String
        let body: String
        let createdAt: Date
        let author: Author?
        let reactionGroups: [ReactionGroupNode]?
        let timelineItems: Timeline
        let reviewThreads: Connection<ReviewThreadNode>
        let commits: Connection<CommitNode>
        let reviewRequests: Connection<Request>
        let latestReviews: Connection<Review>
        let pendingReview: Connection<PendingReviewNode>
        let viewerLatestReview: ViewerLatestReview?
    }

    struct Request: Decodable {
        let requestedReviewer: ReviewerNode?
    }

    struct Review: Decodable {
        let state: ReviewState
        let submittedAt: Date?
        let author: ReviewerNode?

        var latestReview: LatestReview? {
            author?.reviewer.map { LatestReview(reviewer: $0, state: state, submittedAt: submittedAt) }
        }
    }

    struct ViewerLatestReview: Decodable {
        let state: ReviewState
        let submittedAt: Date?
        let commit: Commit?

        struct Commit: Decodable { let oid: String }

        /// Nil for a pending review, which isn't one the viewer has made yet.
        var viewerReview: ViewerReview? {
            guard state != .pending, let commit else { return nil }
            return ViewerReview(state: state, commitOid: commit.oid, submittedAt: submittedAt)
        }
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

private struct ReviewThreadsVariables: Encodable, Sendable {
    let id: String
    let viewer: String?

    // An unknown `viewer` is sent as null rather than left out.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(viewer, forKey: .viewer)
    }

    enum CodingKeys: CodingKey { case id, viewer }
}

private struct ReviewThreadsResponse: Decodable {
    let node: Node?

    /// Both nil for a node that isn't a PR.
    struct Node: Decodable {
        let reviewThreads: Connection<ReviewThreadNode>?
        let pendingReview: Connection<PendingReviewNode>?
    }
}

/// A review thread as the `ReviewThread` fragment returns it.
private struct ReviewThreadNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String
    let line: Int?
    let startLine: Int?
    let diffSide: String?
    let originalLine: Int?
    let originalStartLine: Int?
    let subjectType: String?
    let viewerCanReply: Bool
    let viewerCanResolve: Bool
    let viewerCanUnresolve: Bool
    let resolvedBy: Login?
    let firstComment: Connection<Hunk>
    let comments: Connection<Comment>

    struct Login: Decodable { let login: String }
    struct Hunk: Decodable { let diffHunk: String }

    struct Comment: Decodable {
        let id: String
        let databaseId: Int?
        let bodyHTML: String
        let createdAt: Date
        let isMinimized: Bool
        let minimizedReason: String?
        /// `PENDING` or `SUBMITTED`; taken as submitted when missing, as in captures that
        /// didn't ask for it.
        let state: String?
        /// Taken as false when missing, as in captures that didn't ask for them.
        let viewerCanUpdate: Bool?
        let viewerCanDelete: Bool?
        let author: Author?
        let reactionGroups: [ReactionGroupNode]?
    }

    var thread: ReviewThread {
        ReviewThread(
            id: id, isResolved: isResolved, isOutdated: isOutdated, path: path, line: line, startLine: startLine,
            side: diffSide.flatMap(ReviewThread.Side.init) ?? .right, originalLine: originalLine, originalStartLine: originalStartLine,
            isOnFile: subjectType == "FILE", diffHunk: firstComment.nodes.first?.diffHunk ?? "", resolvedBy: resolvedBy?.login,
            viewerCanReply: viewerCanReply, viewerCanResolve: viewerCanResolve, viewerCanUnresolve: viewerCanUnresolve,
            comments: comments.nodes.map {
                ThreadComment(
                    id: $0.id, databaseId: $0.databaseId, author: $0.author?.participant, createdAt: $0.createdAt, bodyHTML: $0.bodyHTML,
                    isMinimized: $0.isMinimized, minimizedReason: $0.minimizedReason, isPending: $0.state == "PENDING",
                    reactions: $0.reactionGroups.shown, viewerCanUpdate: $0.viewerCanUpdate ?? false, viewerCanDelete: $0.viewerCanDelete ?? false
                )
            }
        )
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
    let databaseId: Int?
    let bodyHTML: String?
    /// A comment's markdown; missing from captures that didn't ask for it.
    let body: String?
    let createdAt: Date?
    let updatedAt: Date?
    let submittedAt: Date?
    let isMinimized: Bool?
    let viewerCanUpdate: Bool?
    let viewerCanDelete: Bool?
    let author: Author?
    let actor: Author?
    let state: ReviewState?
    let comments: Connection<ReviewCommentNode>?
    let commit: Commit?
    let beforeCommit: Oid?
    let afterCommit: Oid?
    let mergeRefName: String?
    let requestedReviewer: Reviewer?
    let reactionGroups: [ReactionGroupNode]?

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
            return TimelineItem(
                id: id, date: createdAt, actor: author?.participant, event: .comment(bodyHTML: bodyHTML ?? "", isMinimized: isMinimized ?? false),
                reactions: reactionGroups.shown, viewerCanUpdate: viewerCanUpdate ?? false, viewerCanDelete: viewerCanDelete ?? false, databaseId: databaseId,
                body: body, updatedAt: updatedAt
            )
        case "PullRequestReview":
            // A pending review has no submission time yet.
            guard let date = submittedAt ?? createdAt else { return nil }
            let comments = (comments?.nodes ?? []).map {
                ReviewComment(id: $0.id, bodyHTML: $0.bodyHTML, path: $0.path, line: $0.line, originalLine: $0.originalLine, diffHunk: $0.diffHunk, isOutdated: $0.outdated, isMinimized: $0.isMinimized, replyTo: $0.replyTo?.id)
            }
            return TimelineItem(
                id: id, date: date, actor: author?.participant, event: .review(state: state ?? .unknown, bodyHTML: bodyHTML ?? "", comments: comments),
                reactions: reactionGroups.shown, viewerCanUpdate: viewerCanUpdate ?? false, databaseId: databaseId
            )
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

/// A `User`, `Bot` or `Team`, which name themselves differently.
struct ReviewerNode: Decodable {
    let __typename: String
    let id: String?
    let login: String?
    let name: String?
    let teamName: String?
    let avatarUrl: String?
    let combinedSlug: String?

    /// Nil for a kind that can't review, such as a mannequin.
    var reviewer: Reviewer? {
        switch __typename {
        case "User":
            login.map { Reviewer(kind: .user, nodeId: id, login: $0, name: name, avatarURL: avatarUrl) }
        case "Bot":
            login.map { Reviewer(kind: .bot, nodeId: id, login: $0, avatarURL: avatarUrl) }
        case "Team":
            combinedSlug.map { Reviewer(kind: .team, nodeId: id, login: $0, name: teamName) }
        default:
            nil
        }
    }
}
