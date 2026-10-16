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

extension GitHubClient {
    /// Starts the viewer's pending review of the PR with `pullRequestId`, holding `threads`,
    /// when `event` is nil; with an event, submits a review at once. `commitId` is the commit
    /// the review is of, whose line numbers the threads use. Returns the review's id.
    @discardableResult
    public func addReview(toPullRequest pullRequestId: String, commitId: String?, body: String?, event: ReviewEvent?, threads: [DraftThread]) async throws -> String {
        let input = AddReviewInput(pullRequestId: pullRequestId, commitOID: commitId, body: body, event: event?.rawValue, threads: threads.map(ThreadInput.init))
        let response: AddReviewResponse = try await query(Self.addReviewMutation, variables: Input(input: input))
        guard let review = response.addPullRequestReview?.pullRequestReview else { throw GitHubError.graphQL(["GitHub didn't return the review"]) }
        return review.id
    }

    /// Adds a comment on a line to the viewer's pending review with `reviewId`, as a new thread.
    public func addThread(_ thread: DraftThread, toReview reviewId: String) async throws {
        let input = AddThreadInput(pullRequestReviewId: reviewId, path: thread.path, line: thread.line, side: thread.side, body: thread.body)
        let _: IgnoredPayload = try await query(Self.addThreadMutation, variables: Input(input: input))
    }

    /// Submits the viewer's pending review with `reviewId`, its summary replaced by `body`.
    public func submitReview(_ reviewId: String, event: ReviewEvent, body: String) async throws {
        let input = SubmitReviewInput(pullRequestReviewId: reviewId, event: event.rawValue, body: body)
        let _: IgnoredPayload = try await query(Self.submitReviewMutation, variables: Input(input: input))
    }

    /// Abandons the viewer's pending review with `reviewId`, and its comments with it.
    public func deleteReview(_ reviewId: String) async throws {
        let _: IgnoredPayload = try await query(Self.deleteReviewMutation, variables: Input(input: DeleteReviewInput(pullRequestReviewId: reviewId)))
    }

    static let addReviewMutation = """
        mutation($input: AddPullRequestReviewInput!) {
          addPullRequestReview(input: $input) { pullRequestReview { id state } }
        }
        """

    static let addThreadMutation = """
        mutation($input: AddPullRequestReviewThreadInput!) {
          addPullRequestReviewThread(input: $input) { thread { id } }
        }
        """

    static let submitReviewMutation = """
        mutation($input: SubmitPullRequestReviewInput!) {
          submitPullRequestReview(input: $input) { pullRequestReview { id state } }
        }
        """

    static let deleteReviewMutation = """
        mutation($input: DeletePullRequestReviewInput!) {
          deletePullRequestReview(input: $input) { pullRequestReview { id } }
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

private struct AddReviewResponse: Decodable {
    let addPullRequestReview: Payload?

    struct Payload: Decodable {
        let pullRequestReview: Review?
    }

    struct Review: Decodable {
        let id: String
    }
}

/// For a mutation whose payload isn't needed; its errors still come through the envelope.
private struct IgnoredPayload: Decodable {}
