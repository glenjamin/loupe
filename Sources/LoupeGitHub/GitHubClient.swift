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
    /// then, so merges and closes come through as changes, though the to-review list's search
    /// of PRs the viewer has reviewed stays to open ones. Either way it follows each search's
    /// pages until they run out; a PR more than one search finds is listed once.
    public func pullRequests(in list: PullRequestList, updatedSince: Date? = nil) async throws -> [PullRequestSummary] {
        var pullRequests: [PullRequestSummary] = []
        for search in Self.searchQueries(list, updatedSince: updatedSince) {
            var cursor: String?
            repeat {
                let variables = SearchVariables(query: search, first: Self.pageSize, after: cursor)
                let response: SearchPageResponse = try await query(Self.searchPageQuery, variables: variables)
                for node in response.search.nodes where !pullRequests.contains(where: { $0.id == node.id }) {
                    pullRequests.append(PullRequestSummary(node))
                }
                cursor = response.search.pageInfo.hasNextPage ? response.search.pageInfo.endCursor : nil
            } while cursor != nil
        }
        return pullRequests
    }

    /// The signed-in user's login.
    public func viewerLogin() async throws -> String {
        let response: ViewerResponse = try await query(Self.viewerQuery, variables: NoVariables())
        return response.viewer.login
    }

    /// The state, pending review requests and latest requests made of each PR in `ids`, keyed
    /// by id. PRs GitHub no longer has (or no longer shows the user) are left out.
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
    public func pullRequests(ids: [String]) async throws -> [PullRequestLookup] {
        var pullRequests: [PullRequestLookup] = []
        for start in stride(from: 0, to: ids.count, by: Self.pageSize) {
            let batch = Array(ids[start..<min(start + Self.pageSize, ids.count)])
            let response: PullRequestNodesResponse = try await query(Self.pullRequestNodesQuery, variables: NodesVariables(ids: batch), allowingMissingNodes: true)
            pullRequests += response.nodes.compactMap { $0.map(PullRequestLookup.init) }
        }
        return pullRequests
    }

    /// The PR numbered `number` in `repository` (`owner/name`) as it is now, as a link names it.
    /// Nil when GitHub has no such PR, or doesn't show it to the viewer.
    public func pullRequest(repository: String, number: Int) async throws -> PullRequestLookup? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let variables = PullRequestNumberVariables(owner: String(parts[0]), name: String(parts[1]), number: number)
        let response: PullRequestByNumberResponse = try await query(Self.pullRequestByNumberQuery, variables: variables, allowingMissingNodes: true)
        return response.repository?.pullRequest.map(PullRequestLookup.init)
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

    func query<Response: Decodable>(
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

    /// To review is what's asked of the viewer and what they've approved or asked changes of,
    /// so it's searched both ways. The second keeps to open PRs, as the to-review check by id
    /// finds those merged since, and leaves out the viewer's own, which they may have commented
    /// on.
    static func searchQueries(_ list: PullRequestList, updatedSince: Date?) -> [String] {
        // Search takes whole seconds; rounding down keeps the boundary inclusive.
        let since = updatedSince.map { "updated:>=\(Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)).formatted(.iso8601)) " } ?? ""
        let state = updatedSince == nil ? "is:open " : ""
        return switch list {
        case .mine: ["is:pr \(state)author:@me \(since)sort:updated-desc"]
        case .toReview: [
            "is:pr \(state)review-requested:@me \(since)sort:updated-desc",
            "is:pr is:open reviewed-by:@me -author:@me \(since)sort:updated-desc",
        ]
        }
    }

    static let viewerQuery = "query { viewer { login } }"

    static let reviewRequestsQuery = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on PullRequest {
              id
              state
              \(reviewRequestFields)
            }
          }
        }
        """

    /// Who the PR's review waits on, its latest requests for review, re-requests included, and
    /// each reviewer's latest approval or request for changes.
    static let reviewRequestFields = """
        reviewRequests(first: 50) {
          nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } }
        }
        requestEvents: timelineItems(last: 20, itemTypes: [REVIEW_REQUESTED_EVENT]) {
          nodes {
            ... on ReviewRequestedEvent {
              createdAt
              requestedReviewer { __typename ... on User { login } ... on Team { slug } }
            }
          }
        }
        latestOpinionatedReviews(first: 50) { nodes { state submittedAt commit { oid } author { login } } }
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
    /// past GitHub's time limit. The review requests say which lists the PR belongs in without
    /// waiting for the searches.
    static let pullRequestNodesQuery = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            ...PullRequestRow
            ... on PullRequest {
              commitCount: commits { totalCount }
              comments { totalCount }
              reviewThreads { totalCount }
              \(reviewRequestFields)
            }
          }
        }
        """ + pullRequestRowFragment

    /// The same fields as the lookup by id, as the PR is then stored and shown the same way.
    static let pullRequestByNumberQuery = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              ...PullRequestRow
              commitCount: commits { totalCount }
              comments { totalCount }
              reviewThreads { totalCount }
              \(reviewRequestFields)
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

struct NodesVariables: Encodable, Sendable {
    let ids: [String]
}

private struct PullRequestNumberVariables: Encodable, Sendable {
    let owner: String
    let name: String
    let number: Int
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

extension GitHubClient {
    /// `text` rendered to HTML by GitHub, as GitHub Flavored Markdown with references resolved
    /// against `repository` (`owner/name`). REST, as GraphQL has no way to render a file.
    public func renderMarkdown(_ text: String, in repository: String) async throws -> String {
        let body = try await post(path: "/markdown", MarkdownRequest(text: text, mode: "gfm", context: repository))
        return String(decoding: body, as: UTF8.self)
    }

    /// POSTs `content` as JSON to a REST endpoint and returns the response's body, throwing
    /// GitHub's message for anything but success. `accept` picks the media type answered with.
    func post(path: String, _ content: some Encodable, accept: String = "application/vnd.github+json") async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.httpMethod = "POST"
        request.setValue("bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(content)

        let (body, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.message
            throw GitHubError.http(status: response.statusCode, message: message)
        }
        return body
    }
}

private struct MarkdownRequest: Encodable {
    let text: String
    let mode: String
    let context: String
}
