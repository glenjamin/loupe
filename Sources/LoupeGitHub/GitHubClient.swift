import Foundation

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

    /// The signed-in user's open PRs and the open PRs awaiting their review, each newest first.
    public func pullRequestLists() async throws -> PullRequestLists {
        let response: PullRequestListsResponse = try await query(Self.pullRequestListsQuery)
        return PullRequestLists(mine: PullRequestPage(response.mine), toReview: PullRequestPage(response.toReview))
    }

    private func query<Response: Decodable>(_ query: String) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["query": query])

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

    // `sort:updated-desc` makes truncation at `first` drop the oldest PRs rather than arbitrary ones.
    static let pullRequestListsQuery = """
        query {
          mine: search(query: "is:pr is:open author:@me sort:updated-desc", type: ISSUE, first: 50) { issueCount nodes { ...PullRequestRow } }
          toReview: search(query: "is:pr is:open review-requested:@me sort:updated-desc", type: ISSUE, first: 50) { issueCount nodes { ...PullRequestRow } }
        }

        fragment PullRequestRow on PullRequest {
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
