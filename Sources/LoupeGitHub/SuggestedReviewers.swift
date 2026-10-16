import Foundation
import LoupeModel

extension GitHubClient {
    /// Who GitHub suggests should review the PR with `id`, in its order: people who have
    /// lately changed or commented on the code it touches, as github.com's reviewer picker
    /// lists under "Suggestions".
    public func suggestedReviewers(pullRequestId id: String) async throws -> [Reviewer] {
        let response: SuggestedReviewersResponse = try await query(Self.suggestedReviewersQuery, variables: SuggestedReviewersVariables(id: id))
        guard let node = response.node else { throw GitHubError.graphQL(["Pull request \(id) not found"]) }
        return node.suggestedReviewers.compactMap(\.self).map {
            Reviewer(kind: .user, nodeId: $0.reviewer.id, login: $0.reviewer.login, name: $0.reviewer.name, avatarURL: $0.reviewer.avatarUrl)
        }
    }

    static let suggestedReviewersQuery = """
        query($id: ID!) {
          node(id: $id) {
            ... on PullRequest { suggestedReviewers { reviewer { id login name avatarUrl } } }
          }
        }
        """
}

private struct SuggestedReviewersVariables: Encodable, Sendable {
    let id: String
}

private struct SuggestedReviewersResponse: Decodable {
    let node: Node?

    struct Node: Decodable {
        /// GitHub's schema allows a null entry.
        let suggestedReviewers: [Suggestion?]
    }

    struct Suggestion: Decodable {
        let reviewer: User
    }

    struct User: Decodable {
        let id: String
        let login: String
        let name: String?
        let avatarUrl: String?
    }
}
