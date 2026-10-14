import Foundation
import LoupeModel

/// Sends one HTTP request. `URLSession` is the real one; tests substitute an in-memory GitHub.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Talks to GitHub's GraphQL API, authenticating with a token fetched fresh for each request so
/// a re-login with `gh` is picked up without restarting.
public struct GitHubClient: Sendable {
    public typealias TokenProvider = @Sendable () async throws -> String

    private let token: TokenProvider
    private let transport: any HTTPTransport
    private let endpoint = URL(string: "https://api.github.com/graphql")!

    public init(token: @escaping TokenProvider = GitHubCLI.authToken, transport: any HTTPTransport = URLSession.shared) {
        self.token = token
        self.transport = transport
    }

    /// Without `updatedSince`, every open PR in `list`. With it, every PR in `list` updated since
    /// then, whatever its state, so merges and closes come through as changes. Either way it
    /// follows the search's pages until they run out.
    public func pullRequests(in list: PullRequestList, updatedSince: Date? = nil) async throws -> [PullRequestSummary] {
        var pullRequests: [PullRequestSummary] = []
        var cursor: String?
        repeat {
            let variables = SearchVariables(query: Self.searchQuery(list, updatedSince: updatedSince), first: Self.pageSize, after: cursor)
            let response: SearchPageResponse = try await query(Self.searchPageQuery, variables: variables)
            pullRequests += response.search.nodes.map(PullRequestSummary.init)
            cursor = response.search.pageInfo.hasNextPage ? response.search.pageInfo.endCursor : nil
        } while cursor != nil
        return pullRequests
    }

    /// The signed-in user's login.
    public func viewerLogin() async throws -> String {
        let response: ViewerResponse = try await query(Self.viewerQuery, variables: NoVariables())
        return response.viewer.login
    }

    /// The state and pending review requests of each PR in `ids`, keyed by id. PRs GitHub no
    /// longer has (or no longer shows the user) are left out.
    public func reviewRequests(for ids: [String]) async throws -> [String: ReviewRequests] {
        var requests: [String: ReviewRequests] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.pageSize) {
            let batch = Array(ids[start..<min(start + Self.pageSize, ids.count)])
            let response: NodesResponse = try await query(Self.reviewRequestsQuery, variables: NodesVariables(ids: batch), allowingMissingNodes: true)
            for case let node? in response.nodes {
                requests[node.id] = ReviewRequests(node)
            }
        }
        return requests
    }

    /// The PRs with `ids` as they are now, looked up directly rather than searched for, so an
    /// open PR's changes can be noticed whichever list it's in, if any. PRs GitHub no longer has
    /// (or no longer shows the user) are left out.
    public func pullRequests(ids: [String]) async throws -> [PullRequestSummary] {
        var pullRequests: [PullRequestSummary] = []
        for start in stride(from: 0, to: ids.count, by: Self.pageSize) {
            let batch = Array(ids[start..<min(start + Self.pageSize, ids.count)])
            let response: PullRequestNodesResponse = try await query(Self.pullRequestNodesQuery, variables: NodesVariables(ids: batch), allowingMissingNodes: true)
            pullRequests += response.nodes.compactMap { $0.map(PullRequestSummary.init) }
        }
        return pullRequests
    }

    /// The viewer's viewed state of every file in the PR with `id`, keyed by path. GitHub lists
    /// vendored files too, so the pages are followed to the end.
    public func viewedStates(ofPullRequest id: String) async throws -> [String: FileViewedState] {
        var states: [String: FileViewedState] = [:]
        var cursor: String?
        repeat {
            let variables = FilesVariables(id: id, first: Self.pageSize, after: cursor)
            let response: FilesResponse = try await query(Self.viewedStatesQuery, variables: variables)
            guard let files = response.node?.files else { throw GitHubError.graphQL(["Pull request \(id) not found"]) }
            for file in files.nodes {
                states[file.path] = file.viewerViewedState
            }
            cursor = files.pageInfo.hasNextPage ? files.pageInfo.endCursor : nil
        } while cursor != nil
        return states
    }

    /// Marks the file at `path` as viewed, or no longer viewed, as github.com's checkbox does.
    public func setFileViewed(_ viewed: Bool, path: String, pullRequestId: String) async throws {
        let mutation = viewed ? Self.markFileAsViewedMutation : Self.unmarkFileAsViewedMutation
        let _: IgnoredResponse = try await query(mutation, variables: FileVariables(pullRequestId: pullRequestId, path: path))
    }

    private func query<Response: Decodable>(
        _ query: String,
        variables: some Encodable & Sendable,
        allowingMissingNodes: Bool = false
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))

        let (body, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.message
            throw GitHubError.http(status: response.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(GraphQLEnvelope<Response>.self, from: body)
        // GitHub can return partial data alongside errors; a partial list would read as complete.
        // A `nodes` lookup reports each id it can't resolve as an error beside a null node.
        if let errors = envelope.errors, !errors.isEmpty, !(allowingMissingNodes && errors.allSatisfy { $0.type == "NOT_FOUND" }) {
            throw GitHubError.graphQL(errors.map(\.message))
        }
        guard let data = envelope.data else { throw GitHubError.graphQL(["Response had no data"]) }
        return data
    }

    /// GitHub's maximum page size.
    static let pageSize = 100

    static func searchQuery(_ list: PullRequestList, updatedSince: Date?) -> String {
        let who = switch list {
        case .mine: "author:@me"
        case .toReview: "review-requested:@me"
        }
        guard let updatedSince else { return "is:pr is:open \(who) sort:updated-desc" }
        // Search takes whole seconds; rounding down keeps the boundary inclusive.
        let since = Date(timeIntervalSince1970: updatedSince.timeIntervalSince1970.rounded(.down))
        return "is:pr \(who) updated:>=\(since.formatted(.iso8601)) sort:updated-desc"
    }

    static let viewerQuery = "query { viewer { login } }"

    static let reviewRequestsQuery = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on PullRequest {
              id
              state
              reviewRequests(first: 50) {
                nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } }
              }
            }
          }
        }
        """

    static let searchPageQuery = """
        query($query: String!, $first: Int!, $after: String) {
          search(query: $query, type: ISSUE, first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ...PullRequestRow }
          }
        }
        """ + pullRequestRowFragment

    /// Counts are asked for only here: on a full page of search results they take the request
    /// past GitHub's time limit.
    static let pullRequestNodesQuery = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            ...PullRequestRow
            ... on PullRequest {
              commitCount: commits { totalCount }
              comments { totalCount }
              reviewThreads { totalCount }
            }
          }
        }
        """ + pullRequestRowFragment

    static let viewedStatesQuery = """
        query($id: ID!, $first: Int!, $after: String) {
          node(id: $id) {
            ... on PullRequest {
              files(first: $first, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { path viewerViewedState }
              }
            }
          }
        }
        """

    static let markFileAsViewedMutation = """
        mutation($pullRequestId: ID!, $path: String!) {
          markFileAsViewed(input: { pullRequestId: $pullRequestId, path: $path }) { pullRequest { id } }
        }
        """

    static let unmarkFileAsViewedMutation = """
        mutation($pullRequestId: ID!, $path: String!) {
          unmarkFileAsViewed(input: { pullRequestId: $pullRequestId, path: $path }) { pullRequest { id } }
        }
        """

    static let pullRequestRowFragment = """

        fragment PullRequestRow on PullRequest {
          id
          number
          title
          url
          isDraft
          state
          mergedAt
          closedAt
          updatedAt
          reviewDecision
          headRefName
          baseRefName
          headRefOid
          baseRefOid
          author { login }
          repository { nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        }
        """
}

public enum GitHubError: Error, Equatable, LocalizedError {
    case http(status: Int, message: String?)
    case graphQL([String])
    case token(String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, message):
            "GitHub returned HTTP \(status)" + (message.map { ": \($0)" } ?? "")
        case let .graphQL(messages):
            "GitHub query failed: " + messages.joined(separator: "; ")
        case let .token(message):
            "Couldn't get a GitHub token from `gh auth token`: \(message)"
        }
    }
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

private struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables
}

private struct SearchVariables: Encodable, Sendable {
    let query: String
    let first: Int
    let after: String?
}

private struct NoVariables: Encodable, Sendable {}

private struct NodesVariables: Encodable, Sendable {
    let ids: [String]
}

private struct FilesVariables: Encodable, Sendable {
    let id: String
    let first: Int
    let after: String?
}

private struct FileVariables: Encodable, Sendable {
    let pullRequestId: String
    let path: String
}

private struct FilesResponse: Decodable {
    let node: Node?

    struct Node: Decodable {
        let files: Files?
    }

    struct Files: Decodable {
        let pageInfo: PageInfo
        let nodes: [File]
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct File: Decodable {
        let path: String
        let viewerViewedState: FileViewedState
    }
}

/// For a mutation whose payload isn't needed; its errors still come through the envelope.
private struct IgnoredResponse: Decodable {}

private struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [Message]?

    struct Message: Decodable {
        let message: String
        let type: String?
    }
}

private struct ErrorBody: Decodable {
    let message: String
}
