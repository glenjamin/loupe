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

    /// Every PR currently in `list`, following the search's pages until they run out.
    public func pullRequests(in list: PullRequestList) async throws -> [PullRequestSummary] {
        var pullRequests: [PullRequestSummary] = []
        var cursor: String?
        repeat {
            let variables = SearchVariables(query: Self.searchQuery(list), first: Self.pageSize, after: cursor)
            let response: SearchPageResponse = try await query(Self.searchPageQuery, variables: variables)
            pullRequests += response.search.nodes.map(PullRequestSummary.init)
            cursor = response.search.pageInfo.hasNextPage ? response.search.pageInfo.endCursor : nil
        } while cursor != nil
        return pullRequests
    }

    private func query<Response: Decodable>(_ query: String, variables: some Encodable & Sendable) async throws -> Response {
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
        if let errors = envelope.errors, !errors.isEmpty {
            throw GitHubError.graphQL(errors.map(\.message))
        }
        guard let data = envelope.data else { throw GitHubError.graphQL(["Response had no data"]) }
        return data
    }

    /// GitHub's maximum page size.
    static let pageSize = 100

    static func searchQuery(_ list: PullRequestList) -> String {
        switch list {
        case .mine: "is:pr is:open author:@me sort:updated-desc"
        case .toReview: "is:pr is:open review-requested:@me sort:updated-desc"
        }
    }

    static let searchPageQuery = """
        query($query: String!, $first: Int!, $after: String) {
          search(query: $query, type: ISSUE, first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ...PullRequestRow }
          }
        }

        fragment PullRequestRow on PullRequest {
          id
          number
          title
          url
          isDraft
          updatedAt
          reviewDecision
          headRefName
          baseRefName
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

private struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [Message]?

    struct Message: Decodable {
        let message: String
    }
}

private struct ErrorBody: Decodable {
    let message: String
}
