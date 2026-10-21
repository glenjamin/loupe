import Foundation
import LoupeModel

extension GitHubClient {
    /// Everyone who can be asked to review a PR in `repository` (`owner/name`): the people who
    /// can be assigned there, then, for an organisation's repo, its teams, each followed to their
    /// last page. Teams the token isn't allowed to read are left out rather than failing.
    public func reviewerCandidates(in repository: String) async throws -> [Reviewer] {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw GitHubError.graphQL(["Not a repository: \(repository)"]) }
        async let teams = teams(owner: parts[0], name: parts[1])
        var users: [Reviewer] = []
        var cursor: String?
        repeat {
            let variables = CandidateVariables(owner: parts[0], name: parts[1], first: Self.pageSize, after: cursor)
            let response: AssignableUsersResponse = try await query(Self.assignableUsersQuery, variables: variables)
            guard let page = response.repository?.assignableUsers else { break }
            users += page.nodes.map {
                Reviewer(kind: .user, nodeId: $0.id, login: $0.login, name: $0.name, avatarURL: $0.avatarUrl)
            }
            cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
        } while cursor != nil
        return try await users + teams
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

    /// Withdraws the requests for `reviewers` to review PR `number` in `repository` (`owner/name`),
    /// leaving everyone else asked and any review they've already submitted. REST, as GraphQL can
    /// only replace the whole set of requests, which would drop anyone asked meanwhile.
    public func removeReviewRequests(from reviewers: [Reviewer], repository: String, number: Int) async throws {
        let removal = RemoveReviewRequests(
            reviewers: reviewers.filter { $0.kind != .team }.map(\.login),
            team_reviewers: reviewers.filter { $0.kind == .team }.map { String($0.login.split(separator: "/").last ?? "") }
        )
        _ = try await rest("DELETE", path: "/repos/\(repository)/pulls/\(number)/requested_reviewers", json: JSONEncoder().encode(removal))
    }

    /// A refusal to read teams comes as a GraphQL error and means none can be offered; any other
    /// failure fails the whole fetch, so it's tried again rather than taken as no teams.
    private func teams(owner: String, name: String) async throws -> [Reviewer] {
        var teams: [Reviewer] = []
        var cursor: String?
        repeat {
            let variables = CandidateVariables(owner: owner, name: name, first: Self.pageSize, after: cursor)
            let response: TeamsResponse
            do {
                response = try await query(Self.teamsQuery, variables: variables)
            } catch GitHubError.graphQL {
                return []
            }
            guard let page = response.repository?.owner.teams else { break }
            teams += page.nodes.map {
                Reviewer(kind: .team, nodeId: $0.id, login: $0.combinedSlug, name: $0.name)
            }
            cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
        } while cursor != nil
        return teams
    }

    static let assignableUsersQuery = """
        query($owner: String!, $name: String!, $first: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            assignableUsers(first: $first, after: $after) {
              pageInfo { hasNextPage endCursor }
              nodes { id login name avatarUrl }
            }
          }
        }
        """

    static let teamsQuery = """
        query($owner: String!, $name: String!, $first: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            owner {
              ... on Organization {
                teams(first: $first, after: $after) {
                  pageInfo { hasNextPage endCursor }
                  nodes { id name combinedSlug }
                }
              }
            }
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
    let first: Int
    let after: String?
}

private struct AssignableUsersResponse: Decodable {
    let repository: Repository?

    struct Repository: Decodable {
        let assignableUsers: Connection
    }

    struct Connection: Decodable {
        let pageInfo: PageInfo
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
        let pageInfo: PageInfo
        let nodes: [Team]
    }

    struct Team: Decodable {
        let id: String
        let name: String
        let combinedSlug: String
    }
}

private struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
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

/// Users and bots by login, teams by slug alone.
private struct RemoveReviewRequests: Encodable {
    let reviewers: [String]
    let team_reviewers: [String]
}
