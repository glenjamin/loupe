import Foundation
import LoupeModel

extension GitHubClient {
    /// Comments on the PR with node id `pullRequestId`, in its conversation rather than on a
    /// line or in a review, returning the comment as the conversation shows it.
    @discardableResult
    public func addComment(_ body: String, toPullRequest pullRequestId: String) async throws -> TimelineItem {
        let response: AddCommentResponse = try await query(Self.addCommentMutation, variables: Input(input: AddCommentInput(subjectId: pullRequestId, body: body)))
        guard let comment = response.addComment?.commentEdge?.node else { throw GitHubError.graphQL(["GitHub didn't return the comment"]) }
        return comment.item
    }

    /// Asks for the fields the conversation's timeline asks of an issue comment.
    static let addCommentMutation = """
        mutation($input: AddCommentInput!) {
          addComment(input: $input) { commentEdge { node { id bodyHTML createdAt isMinimized viewerCanUpdate viewerCanDelete author { login avatarUrl } \(reactionGroupsField) } } }
        }
        """
}

private struct Input<Value: Encodable & Sendable>: Encodable, Sendable {
    let input: Value
}

private struct AddCommentInput: Encodable, Sendable {
    let subjectId: String
    let body: String
}

private struct AddCommentResponse: Decodable {
    let addComment: Payload?

    struct Payload: Decodable {
        let commentEdge: Edge?
    }

    struct Edge: Decodable {
        let node: CommentNode?
    }
}

private struct CommentNode: Decodable {
    let id: String
    let bodyHTML: String
    let createdAt: Date
    let isMinimized: Bool
    let viewerCanUpdate: Bool?
    let viewerCanDelete: Bool?
    let author: AuthorNode?
    let reactionGroups: [ReactionGroupNode]?

    var item: TimelineItem {
        TimelineItem(
            id: id, date: createdAt, actor: author?.participant, event: .comment(bodyHTML: bodyHTML, isMinimized: isMinimized),
            reactions: reactionGroups.shown, viewerCanUpdate: viewerCanUpdate ?? false, viewerCanDelete: viewerCanDelete ?? false
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
