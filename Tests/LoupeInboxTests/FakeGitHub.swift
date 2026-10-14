import Foundation
import LoupeGitHub
import LoupeModel
import Testing

/// An in-memory api.github.com/graphql holding the viewer's PRs and the PRs awaiting their
/// review. Like GitHub it rejects requests without the expected token, caps page sizes, pages
/// with cursors, matches searches by author, review request, state and update time, and bumps a
/// PR's update time when it changes. Tests can change PRs, or make every request fail.
actor FakeGitHub: HTTPTransport {
    enum Failure {
        case status(Int)
        case body(Data)

        static func fixture(_ name: String) throws -> Failure {
            .body(try Data(contentsOf: projectRoot.appending(path: "probe/\(name)")))
        }
    }

    static let validToken = "test-token"
    /// The account the probe was captured as.
    static let viewer = "glenjamin"

    /// In the order search returns them.
    private var pullRequests: [FakePullRequest]
    private let viewerTeams: Set<String>
    private let maxPageSize: Int
    private var failure: Failure?
    private(set) var requestCount = 0
    /// Every search string received, in order.
    private(set) var searches: [String] = []

    /// Serves the PRs captured in a probe response, with review requested of the viewer on
    /// the to-review ones. The probe asked GitHub to sort by update time; `reversed` checks the
    /// app doesn't depend on that.
    init(fixture: String, reversed: Bool = false, maxPageSize: Int = 100, viewerTeams: Set<String> = []) throws {
        let data = try Data(contentsOf: projectRoot.appending(path: "probe/\(fixture)"))
        let probe = try JSONDecoder().decode(ProbeResponse.self, from: data).data
        var toReview = probe.toReview.nodes
        for index in toReview.indices {
            toReview[index].requestedReviewers = [.user(Self.viewer)]
        }
        let all = probe.mine.nodes + toReview
        pullRequests = reversed ? all.reversed() : all
        self.viewerTeams = viewerTeams
        self.maxPageSize = maxPageSize
    }

    nonisolated func client(token: String = validToken) -> GitHubClient {
        client { token }
    }

    nonisolated func client(token: @escaping GitHubClient.TokenProvider) -> GitHubClient {
        GitHubClient(token: token, transport: self)
    }

    /// The open PRs a full load of `list` finds.
    func pullRequests(in list: PullRequestList) -> [FakePullRequest] {
        pullRequests.filter { $0.state == "OPEN" && matches($0, list) }
    }

    /// Changes the PR with `id`, which GitHub records as an update.
    func edit(_ id: String, _ change: @Sendable (inout FakePullRequest) throws -> Void) throws {
        let index = try #require(pullRequests.firstIndex { $0.id == id })
        try change(&pullRequests[index])
        pullRequests[index].updatedAt = Date.now.formatted(.iso8601)
    }

    func merge(_ id: String) throws {
        try edit(id) { pullRequest in
            let now = Date.now.formatted(.iso8601)
            pullRequest.state = "MERGED"
            pullRequest.mergedAt = now
            pullRequest.closedAt = now
        }
    }

    /// As when a PR's repo is deleted, or the viewer loses access to it.
    func delete(_ id: String) {
        pullRequests.removeAll { $0.id == id }
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

        let body = try JSONDecoder().decode(GraphQLRequest.self, from: try #require(request.httpBody))
        let response: any Encodable = if let ids = body.variables.ids {
            try reviewRequests(ids)
        } else if body.variables.query != nil {
            try search(body.variables)
        } else {
            try viewer(body.query)
        }
        return (try JSONEncoder().encode(response), httpResponse(url, status: 200))
    }

    private func search(_ variables: GraphQLRequest.Variables) throws -> Envelope<SearchPayload> {
        let query = try #require(variables.query)
        searches.append(query)
        let search = try #require(SearchQuery(query), "Unexpected search: \(query)")
        let results = pullRequests.filter { pullRequest in
            matches(pullRequest, search.list)
                && (!search.openOnly || pullRequest.state == "OPEN")
                && search.updatedSince.map { updatedAt(pullRequest) >= $0 } ?? true
        }
        let start = try variables.after.map { try #require(Int($0)) } ?? 0
        let first = try #require(variables.first)
        let end = min(start + min(first, maxPageSize), results.count)
        return Envelope(data: SearchPayload(search: .init(
            pageInfo: .init(hasNextPage: end < results.count, endCursor: end > start ? String(end) : nil),
            nodes: Array(results[start..<end])
        )))
    }

    private func viewer(_ query: String) throws -> Envelope<[String: [String: String]]> {
        #expect(query.contains("viewer { login }"))
        return Envelope(data: ["viewer": ["login": Self.viewer]])
    }

    private func reviewRequests(_ ids: [String]) throws -> Envelope<NodesPayload> {
        #expect(ids.count <= 100, "GitHub's nodes lookup takes at most 100 ids")
        let nodes = ids.map { id in
            pullRequests.first { $0.id == id }.map { pullRequest in
                NodesPayload.Node(id: id, state: pullRequest.state, reviewRequests: .init(nodes: pullRequest.requestedReviewers.map { reviewer in
                    switch reviewer {
                    case let .user(login): .init(requestedReviewer: .init(__typename: "User", login: login, slug: nil))
                    case let .team(slug): .init(requestedReviewer: .init(__typename: "Team", login: nil, slug: slug))
                    }
                }))
            }
        }
        let missing = zip(ids, nodes).enumerated().compactMap { index, pair in
            pair.1 == nil ? Envelope<NodesPayload>.GraphQLError(type: "NOT_FOUND", path: ["nodes", String(index)], message: "Could not resolve to a node with the global id of '\(pair.0)'") : nil
        }
        return Envelope(data: NodesPayload(nodes: nodes), errors: missing.isEmpty ? nil : missing)
    }

    private func matches(_ pullRequest: FakePullRequest, _ list: PullRequestList) -> Bool {
        switch list {
        case .mine:
            pullRequest.author?.login == Self.viewer
        case .toReview:
            pullRequest.requestedReviewers.contains { reviewer in
                switch reviewer {
                case let .user(login): login == Self.viewer
                case let .team(slug): viewerTeams.contains(slug)
                }
            }
        }
    }

    private func updatedAt(_ pullRequest: FakePullRequest) -> Date {
        (try? Date(pullRequest.updatedAt, strategy: .iso8601)) ?? .distantPast
    }
}

/// A search result node, in GitHub's JSON shape, plus who its review is requested from.
struct FakePullRequest: Codable, Sendable {
    let id: String
    let number: Int
    var title: String
    let url: String
    var isDraft: Bool
    var state: String
    var mergedAt: String?
    var closedAt: String?
    var updatedAt: String
    var reviewDecision: String?
    let headRefName: String
    let baseRefName: String
    let author: Login?
    let repository: Repository
    var commits: Commits
    var requestedReviewers: [Reviewer] = []

    enum Reviewer: Sendable {
        case user(String)
        case team(String)
    }

    struct Login: Codable, Sendable { let login: String }
    struct Repository: Codable, Sendable { let nameWithOwner: String }
    struct Commits: Codable, Sendable { var nodes: [CommitNode] }
    struct CommitNode: Codable, Sendable { var commit: Commit }
    struct Commit: Codable, Sendable { var statusCheckRollup: Rollup? }
    struct Rollup: Codable, Sendable { var state: String }

    enum CodingKeys: String, CodingKey {
        case id, number, title, url, isDraft, state, mergedAt, closedAt, updatedAt, reviewDecision
        case headRefName, baseRefName, author, repository, commits
    }

    /// The probe's PRs predate asking for `state`; they were all open.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "OPEN"
        mergedAt = try container.decodeIfPresent(String.self, forKey: .mergedAt)
        closedAt = try container.decodeIfPresent(String.self, forKey: .closedAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
        headRefName = try container.decode(String.self, forKey: .headRefName)
        baseRefName = try container.decode(String.self, forKey: .baseRefName)
        author = try container.decodeIfPresent(Login.self, forKey: .author)
        repository = try container.decode(Repository.self, forKey: .repository)
        commits = try container.decode(Commits.self, forKey: .commits)
    }
}

let projectRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A start-screen search string, checked against the shapes the app should send: a full load is
/// open PRs only; a refresh asks for every state updated since a whole-second UTC time.
private struct SearchQuery {
    let list: PullRequestList
    let openOnly: Bool
    let updatedSince: Date?

    init?(_ query: String) {
        let pattern = /is:pr (?<open>is:open )?(?<who>author|review-requested):@me (updated:>=(?<since>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) )?sort:updated-desc/
        guard let match = query.wholeMatch(of: pattern) else { return nil }
        list = match.who == "author" ? .mine : .toReview
        openOnly = match.open != nil
        updatedSince = match.since.flatMap { try? Date(String($0), strategy: .iso8601) }
        guard openOnly != (updatedSince != nil) else { return nil }
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

private struct GraphQLRequest: Decodable {
    let query: String
    let variables: Variables

    struct Variables: Decodable {
        let query: String?
        let first: Int?
        let after: String?
        let ids: [String]?
    }
}

private struct Envelope<Payload: Encodable>: Encodable {
    let data: Payload
    var errors: [GraphQLError]?

    struct GraphQLError: Encodable {
        let type: String
        /// GitHub mixes field names and indexes; strings are close enough here.
        let path: [String]
        let message: String
    }
}

private struct SearchPayload: Encodable {
    let search: Search

    struct Search: Encodable {
        let pageInfo: PageInfo
        let nodes: [FakePullRequest]
    }

    struct PageInfo: Encodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

private struct NodesPayload: Encodable {
    let nodes: [Node?]

    struct Node: Encodable {
        let id: String
        let state: String
        let reviewRequests: Connection
    }

    struct Connection: Encodable { let nodes: [Request] }
    struct Request: Encodable { let requestedReviewer: Reviewer }

    struct Reviewer: Encodable {
        let __typename: String
        let login: String?
        let slug: String?
    }
}
