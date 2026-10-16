import Foundation

/// What kind of thing an edited body belongs to, as each has its own mutation.
public enum EditedComment: Sendable, Equatable {
    /// A comment in a review thread, pending or submitted.
    case reviewComment
    /// A comment in the PR's conversation.
    case issueComment
    /// A review's summary.
    case review
}

extension GitHubClient {
    /// The markdown of the comment or review with node id `id` as it is on GitHub now: what
    /// editing it should start from, as it may have been edited on github.com since.
    public func commentBody(id: String) async throws -> String {
        let response: CommentBodyResponse = try await query(Self.commentBodyQuery, variables: CommentBodyVariables(id: id))
        guard let body = response.node?.body else { throw GitHubError.graphQL(["Comment \(id) not found"]) }
        return body
    }

    /// Replaces the body of the comment or review with node id `id` with `body`, in markdown,
    /// returning GitHub's rendering of it.
    public func updateComment(_ kind: EditedComment, id: String, body: String) async throws -> String {
        let bodyHTML: String?
        switch kind {
        case .reviewComment:
            let input = UpdateReviewCommentInput(pullRequestReviewCommentId: id, body: body)
            let response: UpdateReviewCommentResponse = try await query(Self.updateReviewCommentMutation, variables: Input(input: input))
            bodyHTML = response.updatePullRequestReviewComment?.pullRequestReviewComment?.bodyHTML
        case .issueComment:
            let response: UpdateIssueCommentResponse = try await query(Self.updateIssueCommentMutation, variables: Input(input: UpdateIssueCommentInput(id: id, body: body)))
            bodyHTML = response.updateIssueComment?.issueComment?.bodyHTML
        case .review:
            let input = UpdateReviewInput(pullRequestReviewId: id, body: body)
            let response: UpdateReviewResponse = try await query(Self.updateReviewMutation, variables: Input(input: input))
            bodyHTML = response.updatePullRequestReview?.pullRequestReview?.bodyHTML
        }
        guard let bodyHTML else { throw GitHubError.graphQL(["GitHub didn't return the comment"]) }
        return bodyHTML
    }

    /// Deletes the comment on the PR itself with node id `id`. A thread comment is deleted with
    /// `deleteReviewComment`.
    public func deleteIssueComment(_ id: String) async throws {
        let _: IgnoredPayload = try await query(Self.deleteIssueCommentMutation, variables: Input(input: DeleteIssueCommentInput(id: id)))
    }

    static let commentBodyQuery = """
        query($id: ID!) {
          node(id: $id) { ... on IssueComment { body } ... on PullRequestReviewComment { body } ... on PullRequestReview { body } }
        }
        """

    static let updateReviewCommentMutation = """
        mutation($input: UpdatePullRequestReviewCommentInput!) {
          updatePullRequestReviewComment(input: $input) { pullRequestReviewComment { id bodyHTML } }
        }
        """

    static let updateIssueCommentMutation = """
        mutation($input: UpdateIssueCommentInput!) {
          updateIssueComment(input: $input) { issueComment { id bodyHTML } }
        }
        """

    static let deleteIssueCommentMutation = """
        mutation($input: DeleteIssueCommentInput!) {
          deleteIssueComment(input: $input) { clientMutationId }
        }
        """

    static let updateReviewMutation = """
        mutation($input: UpdatePullRequestReviewInput!) {
          updatePullRequestReview(input: $input) { pullRequestReview { id bodyHTML } }
        }
        """
}

private struct Input<Value: Encodable & Sendable>: Encodable, Sendable {
    let input: Value
}

private struct CommentBodyVariables: Encodable, Sendable {
    let id: String
}

/// `body` is nil for a node that's none of the three.
private struct CommentBodyResponse: Decodable {
    let node: Node?

    struct Node: Decodable {
        let body: String?
    }
}

private struct UpdateReviewCommentInput: Encodable, Sendable {
    let pullRequestReviewCommentId: String
    let body: String
}

private struct UpdateIssueCommentInput: Encodable, Sendable {
    let id: String
    let body: String
}

private struct UpdateReviewInput: Encodable, Sendable {
    let pullRequestReviewId: String
    let body: String
}

private struct UpdateReviewCommentResponse: Decodable {
    let updatePullRequestReviewComment: Payload?

    struct Payload: Decodable {
        let pullRequestReviewComment: Edited?
    }
}

private struct UpdateIssueCommentResponse: Decodable {
    let updateIssueComment: Payload?

    struct Payload: Decodable {
        let issueComment: Edited?
    }
}

private struct UpdateReviewResponse: Decodable {
    let updatePullRequestReview: Payload?

    struct Payload: Decodable {
        let pullRequestReview: Edited?
    }
}

private struct DeleteIssueCommentInput: Encodable, Sendable {
    let id: String
}

/// GitHub answers with nothing of note, the comment being gone; an error is what matters.
private struct IgnoredPayload: Decodable {}

/// What each mutation answers with of what it edited.
private struct Edited: Decodable {
    let id: String
    let bodyHTML: String
}
