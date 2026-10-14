import Foundation
import LoupeModel

extension GitHubClient {
    /// Who can be asked to review a PR in `repository` (`owner/name`) matching `text`: the
    /// people who can be assigned there, then, for an organisation's repo, its teams. Teams the
    /// token can't read are left out rather than failing the search.
    public func reviewerCandidates(in repository: String, matching text: String) async throws -> [Reviewer] {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw GitHubError.graphQL(["Not a repository: \(repository)"]) }
        let variables = CandidateVariables(owner: parts[0], name: parts[1], text: text)
        async let teams = try? await teams(variables)
        let response: AssignableUsersResponse = try await query(Self.assignableUsersQuery, variables: variables)
        let users = response.repository?.assignableUsers.nodes.map {
            Reviewer(kind: .user, nodeId: $0.id, login: $0.login, name: $0.name, avatarURL: $0.avatarUrl)
        }
        return (users ?? []) + (await teams ?? [])
    }

    /// Asks `reviewers` to review the PR with `pullRequestId`, adding to those already asked.
    /// Asking someone who has reviewed asks them again. Reviewers without a node id are skipped.
    public func requestReviews(from reviewers: [Reviewer], onPullRequest pullRequestId: String) async throws {
        func ids(_ kind: Reviewer.Kind) -> [String] {
            reviewers.filter { $0.kind == kind }.compactMap(\.nodeId)
        }
        let input = RequestReviewsInput(pullRequestId: pullRequestId, userIds: ids(.user), teamIds: ids(.team), botIds: ids(.bot), union: true)
        let _: RequestReviewsResponse = try await query(Self.requestReviewsMutation, variables: RequestReviewsVariables(input: input))
    }

    private func teams(_ variables: CandidateVariables) async throws -> [Reviewer] {
        let response: TeamsResponse = try await query(Self.teamsQuery, variables: variables)
        return response.repository?.owner.teams?.nodes.map {
            Reviewer(kind: .team, nodeId: $0.id, login: $0.combinedSlug, name: $0.name)
        } ?? []
    }

    static let assignableUsersQuery = """
        query($owner: String!, $name: String!, $text: String!) {
          repository(owner: $owner, name: $name) {
            assignableUsers(first: 30, query: $text) { nodes { id login name avatarUrl } }
          }
        }
        """

    static let teamsQuery = """
        query($owner: String!, $name: String!, $text: String!) {
          repository(owner: $owner, name: $name) {
            owner { ... on Organization { teams(first: 20, query: $text) { nodes { id name combinedSlug } } } }
          }
        }
        """

    static let requestReviewsMutation = """
        mutation($input: RequestReviewsInput!) {
          requestReviews(input: $input) { clientMutationId }
        }
        """
}

private struct CandidateVariables: Encodable, Sendable {
    let owner: String
    let name: String
    let text: String
}

private struct AssignableUsersResponse: Decodable {
    let repository: Repository?

    struct Repository: Decodable {
        let assignableUsers: Connection
    }

    struct Connection: Decodable {
        let nodes: [User]
    }

    struct User: Decodable {
        let id: String
        let login: String
        let name: String?
        let avatarUrl: String?
    }
}

private struct TeamsResponse: Decodable {
    let repository: Repository?

    struct Repository: Decodable {
        let owner: Owner
    }

    /// A user's repo has an owner with no teams.
    struct Owner: Decodable {
        let teams: Connection?
    }

    struct Connection: Decodable {
        let nodes: [Team]
    }

    struct Team: Decodable {
        let id: String
        let name: String
        let combinedSlug: String
    }
}

private struct RequestReviewsVariables: Encodable, Sendable {
    let input: RequestReviewsInput
}

private struct RequestReviewsInput: Encodable, Sendable {
    let pullRequestId: String
    let userIds: [String]
    let teamIds: [String]
    let botIds: [String]
    let union: Bool
}

private struct RequestReviewsResponse: Decodable {}
