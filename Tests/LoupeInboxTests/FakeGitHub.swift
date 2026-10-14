import Foundation
import LoupeGitHub
import LoupeModel
import Testing

/// An in-memory api.github.com/graphql holding the PRs each start-screen search finds. Like
/// GitHub it rejects requests without the expected token, caps page sizes and pages with cursors.
/// Tests can change the PRs a search finds, or make every request fail.
actor FakeGitHub: HTTPTransport {
    enum Failure {
        case status(Int)
        case body(Data)

        static func fixture(_ name: String) throws -> Failure {
            .body(try Data(contentsOf: projectRoot.appending(path: "probe/\(name)")))
        }
    }

    static let validToken = "test-token"

    private var searches: [PullRequestList: [FakePullRequest]]
    private let maxPageSize: Int
    private var failure: Failure?
    private(set) var requestCount = 0

    /// Serves the PRs captured in a probe response as each search's complete results. The probe
    /// asked GitHub to sort by update time; `reversed` checks the app doesn't depend on that.
    init(fixture: String, reversed: Bool = false, maxPageSize: Int = 100) throws {
        let data = try Data(contentsOf: projectRoot.appending(path: "probe/\(fixture)"))
        let probe = try JSONDecoder().decode(ProbeResponse.self, from: data).data
        searches = [
            .mine: reversed ? probe.mine.nodes.reversed() : probe.mine.nodes,
            .toReview: reversed ? probe.toReview.nodes.reversed() : probe.toReview.nodes,
        ]
        self.maxPageSize = maxPageSize
    }

    nonisolated func client(token: String = validToken) -> GitHubClient {
        client { token }
    }

    nonisolated func client(token: @escaping GitHubClient.TokenProvider) -> GitHubClient {
        GitHubClient(token: token, transport: self)
    }

    func pullRequests(in list: PullRequestList) -> [FakePullRequest] {
        searches[list, default: []]
    }

    func edit(_ list: PullRequestList, _ change: @Sendable (inout [FakePullRequest]) throws -> Void) rethrows {
        try change(&searches[list, default: []])
    }

    func fail(with failure: Failure) {
        self.failure = failure
    }

    func recover() {
        failure = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://api.github.com/graphql")
        #expect(request.httpMethod == "POST")

        guard request.value(forHTTPHeaderField: "Authorization") == "bearer \(Self.validToken)" else {
            let body = #"{"message":"Bad credentials","documentation_url":"https://docs.github.com/graphql","status":"401"}"#
            return (Data(body.utf8), httpResponse(url, status: 401))
        }
        switch failure {
        case let .status(status): return (Data(), httpResponse(url, status: status))
        case let .body(data): return (data, httpResponse(url, status: 200))
        case nil: break
        }

        let variables = try JSONDecoder().decode(SearchRequest.self, from: try #require(request.httpBody)).variables
        let list = try #require(PullRequestList.allCases.first { variables.query == searchQuery($0) })
        let results = searches[list, default: []]
        let start = try variables.after.map { try #require(Int($0)) } ?? 0
        let end = min(start + min(variables.first, maxPageSize), results.count)
        let page = SearchPage(data: .init(search: .init(
            pageInfo: .init(hasNextPage: end < results.count, endCursor: end > start ? String(end) : nil),
            nodes: Array(results[start..<end])
        )))
        return (try JSONEncoder().encode(page), httpResponse(url, status: 200))
    }
}

/// A search result node, in GitHub's JSON shape.
struct FakePullRequest: Codable, Sendable {
    let id: String
    let number: Int
    var title: String
    let url: String
    var isDraft: Bool
    var updatedAt: String
    var reviewDecision: String?
    let headRefName: String
    let baseRefName: String
    let author: Login?
    let repository: Repository
    var commits: Commits

    struct Login: Codable, Sendable { let login: String }
    struct Repository: Codable, Sendable { let nameWithOwner: String }
    struct Commits: Codable, Sendable { var nodes: [CommitNode] }
    struct CommitNode: Codable, Sendable { var commit: Commit }
    struct Commit: Codable, Sendable { var statusCheckRollup: Rollup? }
    struct Rollup: Codable, Sendable { var state: String }
}

let projectRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func searchQuery(_ list: PullRequestList) -> String {
    switch list {
    case .mine: "is:pr is:open author:@me sort:updated-desc"
    case .toReview: "is:pr is:open review-requested:@me sort:updated-desc"
    }
}

private func httpResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
}

private struct ProbeResponse: Decodable {
    let data: Searches

    struct Searches: Decodable {
        let mine: Search
        let toReview: Search
    }

    struct Search: Decodable {
        let nodes: [FakePullRequest]
    }
}

private struct SearchRequest: Decodable {
    let variables: Variables

    struct Variables: Decodable {
        let query: String
        let first: Int
        let after: String?
    }
}

private struct SearchPage: Encodable {
    let data: Payload

    struct Payload: Encodable { let search: Search }

    struct Search: Encodable {
        let pageInfo: PageInfo
        let nodes: [FakePullRequest]
    }

    struct PageInfo: Encodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}
