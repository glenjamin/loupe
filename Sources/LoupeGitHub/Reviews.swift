import Foundation
import LoupeModel

/// A PR's review threads and the viewer's pending review, as fetched together.
public struct ReviewThreads: Sendable, Equatable {
    public var threads: [ReviewThread]
    public var pendingReview: PendingReview?
}

/// A comment on one line, as a review's new thread.
public struct DraftThread: Sendable, Equatable {
    public var path: String
    /// A file line number on `side`.
    public var line: Int
    /// `LEFT` for the base, `RIGHT` for the head.
    public var side: String
    public var body: String

    public init(path: String, line: Int, side: String, body: String) {
        self.path = path
        self.line = line
        self.side = side
        self.body = body
    }
}

/// A review as GitHub answers starting or submitting it.
public struct PostedReview: Sendable, Equatable {
    public var id: String
    public var state: ReviewState
    public var bodyHTML: String
    /// When it was submitted, or started for one still pending.
    public var date: Date
    public var author: Participant?
    /// The comment it started with, for a review started holding one.
    public var comments: [ThreadComment]

    public init(id: String, state: ReviewState, bodyHTML: String, date: Date, author: Participant?, comments: [ThreadComment]) {
        self.id = id
        self.state = state
        self.bodyHTML = bodyHTML
        self.date = date
        self.author = author
        self.comments = comments
    }
}

/// A thread added to a pending review, with its one comment, as GitHub answers it.
public struct PostedThread: Sendable, Equatable {
    public var id: String
    public var comment: ThreadComment

    public init(id: String, comment: ThreadComment) {
        self.id = id
        self.comment = comment
    }
}

extension GitHubClient {
    /// Starts the viewer's pending review of the PR with `pullRequestId`, holding `threads`,
    /// when `event` is nil; with an event, submits a review at once. `commitId` is the commit
    /// the review is of, whose line numbers the threads use.
    @discardableResult
    public func addReview(toPullRequest pullRequestId: String, commitId: String?, body: String?, event: ReviewEvent?, threads: [DraftThread]) async throws -> PostedReview {
        let input = AddReviewInput(pullRequestId: pullRequestId, commitOID: commitId, body: body, event: event?.rawValue, threads: threads.map(ThreadInput.init))
        let response: AddReviewResponse = try await query(Self.addReviewMutation, variables: Input(input: input))
        guard let review = response.addPullRequestReview?.pullRequestReview else { throw GitHubError.graphQL(["GitHub didn't return the review"]) }
        return review.posted
    }

    /// Adds a comment on a line to the viewer's pending review with `reviewId`, as a new thread.
    @discardableResult
    public func addThread(_ thread: DraftThread, toReview reviewId: String) async throws -> PostedThread {
        let input = AddThreadInput(pullRequestReviewId: reviewId, path: thread.path, line: thread.line, side: thread.side, body: thread.body)
        let response: AddThreadResponse = try await query(Self.addThreadMutation, variables: Input(input: input))
        guard let thread = response.addPullRequestReviewThread?.thread, let comment = thread.comments.nodes.first else {
            throw GitHubError.graphQL(["GitHub didn't return the comment"])
        }
        return PostedThread(id: thread.id, comment: comment.comment)
    }

    /// Submits the viewer's pending review with `reviewId`, its summary replaced by `body`.
    @discardableResult
    public func submitReview(_ reviewId: String, event: ReviewEvent, body: String) async throws -> PostedReview {
        let input = SubmitReviewInput(pullRequestReviewId: reviewId, event: event.rawValue, body: body)
        let response: SubmitReviewResponse = try await query(Self.submitReviewMutation, variables: Input(input: input))
        guard let review = response.submitPullRequestReview?.pullRequestReview else { throw GitHubError.graphQL(["GitHub didn't return the review"]) }
        return review.posted
    }

    /// Abandons the viewer's pending review with `reviewId`, and its comments with it.
    public func deleteReview(_ reviewId: String) async throws {
        let _: IgnoredPayload = try await query(Self.deleteReviewMutation, variables: Input(input: DeleteReviewInput(pullRequestReviewId: reviewId)))
    }

    /// Deletes the review comment with node id `commentId`, such as one of the viewer's pending
    /// review's; a thread left with no comments goes with it.
    public func deleteReviewComment(_ commentId: String) async throws {
        let _: IgnoredPayload = try await query(Self.deleteReviewCommentMutation, variables: Input(input: DeleteReviewCommentInput(id: commentId)))
    }

    static let addReviewMutation = """
        mutation($input: AddPullRequestReviewInput!) {
          addPullRequestReview(input: $input) { pullRequestReview { ...PostedReview } }
        }
        """ + postedReviewFragment + postedCommentFragment

    static let addThreadMutation = """
        mutation($input: AddPullRequestReviewThreadInput!) {
          addPullRequestReviewThread(input: $input) { thread { id comments(first: 1) { nodes { ...PostedComment } } } }
        }
        """ + postedCommentFragment

    static let submitReviewMutation = """
        mutation($input: SubmitPullRequestReviewInput!) {
          submitPullRequestReview(input: $input) { pullRequestReview { ...PostedReview } }
        }
        """ + postedReviewFragment + postedCommentFragment

    static let deleteReviewMutation = """
        mutation($input: DeletePullRequestReviewInput!) {
          deletePullRequestReview(input: $input) { pullRequestReview { id } }
        }
        """

    static let deleteReviewCommentMutation = """
        mutation($input: DeletePullRequestReviewCommentInput!) {
          deletePullRequestReviewComment(input: $input) { pullRequestReview { id } }
        }
        """

    /// What the timeline shows of a review, and the comment a review started holding.
    static let postedReviewFragment = """

        fragment PostedReview on PullRequestReview {
          id state bodyHTML createdAt submittedAt author { login avatarUrl }
          comments(first: 1) { nodes { ...PostedComment } }
        }
        """

    /// What a thread shows of a comment.
    static let postedCommentFragment = """

        fragment PostedComment on PullRequestReviewComment {
          id databaseId bodyHTML createdAt state viewerCanUpdate viewerCanDelete author { login avatarUrl }
        }
        """
}

private struct Input<Value: Encodable & Sendable>: Encodable, Sendable {
    let input: Value
}

/// Optional fields left out when nil, as GitHub takes a missing `event` to mean pending.
private struct AddReviewInput: Encodable, Sendable {
    let pullRequestId: String
    let commitOID: String?
    let body: String?
    let event: String?
    let threads: [ThreadInput]
}

private struct ThreadInput: Encodable, Sendable {
    let path: String
    let line: Int
    let side: String
    let body: String

    init(_ thread: DraftThread) {
        path = thread.path
        line = thread.line
        side = thread.side
        body = thread.body
    }
}

private struct AddThreadInput: Encodable, Sendable {
    let pullRequestReviewId: String
    let path: String
    let line: Int
    let side: String
    let body: String
}

private struct SubmitReviewInput: Encodable, Sendable {
    let pullRequestReviewId: String
    let event: String
    let body: String
}

private struct DeleteReviewInput: Encodable, Sendable {
    let pullRequestReviewId: String
}

private struct DeleteReviewCommentInput: Encodable, Sendable {
    let id: String
}

private struct AddReviewResponse: Decodable {
    let addPullRequestReview: Payload?

    struct Payload: Decodable {
        let pullRequestReview: ReviewNode?
    }
}

private struct AddThreadResponse: Decodable {
    let addPullRequestReviewThread: Payload?

    struct Payload: Decodable {
        let thread: Thread?
    }

    struct Thread: Decodable {
        let id: String
        let comments: Nodes<CommentNode>
    }
}

private struct SubmitReviewResponse: Decodable {
    let submitPullRequestReview: Payload?

    struct Payload: Decodable {
        let pullRequestReview: ReviewNode?
    }
}

/// A review as the `PostedReview` fragment returns it.
private struct ReviewNode: Decodable {
    let id: String
    let state: ReviewState
    let bodyHTML: String
    let createdAt: Date
    let submittedAt: Date?
    let author: AuthorNode?
    let comments: Nodes<CommentNode>

    var posted: PostedReview {
        PostedReview(id: id, state: state, bodyHTML: bodyHTML, date: submittedAt ?? createdAt, author: author?.participant, comments: comments.nodes.map(\.comment))
    }
}

/// A comment as the `PostedComment` fragment returns it.
private struct CommentNode: Decodable {
    let id: String
    let databaseId: Int?
    let bodyHTML: String
    let createdAt: Date
    let state: String?
    let viewerCanUpdate: Bool?
    let viewerCanDelete: Bool?
    let author: AuthorNode?

    var comment: ThreadComment {
        ThreadComment(
            id: id, databaseId: databaseId, author: author?.participant, createdAt: createdAt, bodyHTML: bodyHTML, isMinimized: false,
            isPending: state == "PENDING", viewerCanUpdate: viewerCanUpdate ?? false, viewerCanDelete: viewerCanDelete ?? false
        )
    }
}

private struct AuthorNode: Decodable {
    let login: String
    let avatarUrl: String?

    var participant: Participant {
        Participant(login: login, avatarURL: avatarUrl)
    }
}

private struct Nodes<Node: Decodable>: Decodable {
    let nodes: [Node]
}

/// For a mutation whose payload isn't needed; its errors still come through the envelope.
private struct IgnoredPayload: Decodable {}
