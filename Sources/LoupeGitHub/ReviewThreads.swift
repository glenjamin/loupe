import Foundation
import LoupeModel

extension GitHubClient {
    /// Replies to a review thread at once, outside any pending review, as github.com's "Add
    /// single comment" does, and returns the reply. `commentId` is the REST id of the thread's
    /// first comment. REST, as GraphQL documents its reply mutation only as adding to a pending
    /// review.
    @discardableResult
    public func replyToThread(startedBy commentId: Int, body: String, inPullRequest number: Int, of repository: String) async throws -> ThreadComment {
        let answer = try await post(path: "/repos/\(repository)/pulls/\(number)/comments/\(commentId)/replies", ReplyRequest(body: body), accept: Self.withHTML)
        return try RESTComment.decode(answer).comment
    }

    /// Starts a review thread with one comment at once, outside any pending review, on `line`
    /// of `path` as of `commitId`: the head for side RIGHT, the base for LEFT, and returns the
    /// comment. A comment on several lines names its first with `start`. REST, as GraphQL's
    /// mutation for a new thread adds it to a pending review and takes no commit; REST doesn't
    /// say which thread it started.
    @discardableResult
    public func addReviewComment(
        _ body: String, path: String, line: Int, side: String, start: (line: Int, side: String)? = nil, commitId: String, inPullRequest number: Int, of repository: String
    ) async throws -> ThreadComment {
        let comment = NewCommentRequest(body: body, commit_id: commitId, path: path, line: line, side: side, start_line: start?.line, start_side: start?.side)
        let answer = try await post(path: "/repos/\(repository)/pulls/\(number)/comments", comment, accept: Self.withHTML)
        return try RESTComment.decode(answer).comment
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

    /// Asks REST for a comment's `body_html` beside its markdown, as GraphQL's `bodyHTML`.
    static let withHTML = "application/vnd.github.full+json"
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
    /// Left out for a comment on one line.
    let start_line: Int?
    let start_side: String?
}

/// A review comment as REST answers posting one, in its own field names.
private struct RESTComment: Decodable {
    let node_id: String
    let id: Int
    let body_html: String
    let created_at: Date
    let user: User?

    struct User: Decodable {
        let login: String
        let avatar_url: String?
    }

    static func decode(_ data: Data) throws -> RESTComment {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RESTComment.self, from: data)
    }

    /// The viewer's own, just posted, so theirs to edit and delete; REST doesn't say so itself.
    var comment: ThreadComment {
        ThreadComment(
            id: node_id, databaseId: id, author: user.map { Participant(login: $0.login, avatarURL: $0.avatar_url) },
            createdAt: created_at, bodyHTML: body_html, isMinimized: false, viewerCanUpdate: true, viewerCanDelete: true
        )
    }
}

private struct ThreadVariables: Encodable, Sendable {
    let threadId: String
}

/// For a mutation whose payload isn't needed; its errors still come through the envelope.
private struct IgnoredPayload: Decodable {}
