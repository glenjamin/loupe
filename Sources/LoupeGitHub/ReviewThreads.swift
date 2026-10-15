import Foundation

extension GitHubClient {
    /// Replies to a review thread at once, outside any pending review, as github.com's "Add
    /// single comment" does. `commentId` is the REST id of the thread's first comment.
    /// REST, as GraphQL documents its reply mutation only as adding to a pending review.
    public func replyToThread(startedBy commentId: Int, body: String, inPullRequest number: Int, of repository: String) async throws {
        _ = try await post(path: "/repos/\(repository)/pulls/\(number)/comments/\(commentId)/replies", ReplyRequest(body: body))
    }

    /// Starts a review thread with one comment at once, outside any pending review, on `line`
    /// of `path` as of `commitId`: the head for side RIGHT, the base for LEFT. REST, as
    /// GraphQL's mutation for a new thread adds it to a pending review.
    public func addReviewComment(_ body: String, path: String, line: Int, side: String, commitId: String, inPullRequest number: Int, of repository: String) async throws {
        let comment = NewCommentRequest(body: body, commit_id: commitId, path: path, line: line, side: side)
        _ = try await post(path: "/repos/\(repository)/pulls/\(number)/comments", comment)
    }

    /// Marks a review thread resolved, or no longer resolved.
    public func setThreadResolved(_ resolved: Bool, threadId: String) async throws {
        let mutation = resolved ? Self.resolveReviewThreadMutation : Self.unresolveReviewThreadMutation
        let _: IgnoredPayload = try await query(mutation, variables: ThreadVariables(threadId: threadId))
    }

    static let resolveReviewThreadMutation = """
        mutation($threadId: ID!) {
          resolveReviewThread(input: { threadId: $threadId }) { thread { id isResolved } }
        }
        """

    static let unresolveReviewThreadMutation = """
        mutation($threadId: ID!) {
          unresolveReviewThread(input: { threadId: $threadId }) { thread { id isResolved } }
        }
        """
}

private struct ReplyRequest: Encodable {
    let body: String
}

/// In the REST API's own field names.
private struct NewCommentRequest: Encodable {
    let body: String
    let commit_id: String
    let path: String
    let line: Int
    let side: String
}

private struct ThreadVariables: Encodable, Sendable {
    let threadId: String
}

/// For a mutation whose payload isn't needed; its errors still come through the envelope.
private struct IgnoredPayload: Decodable {}
