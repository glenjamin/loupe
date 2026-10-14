import Foundation
import LoupeGitHub
import LoupeModel
import Testing

/// An in-memory api.github.com holding the viewer's PRs and the PRs awaiting their review. Like
/// GitHub's GraphQL API it rejects requests without the expected token, caps page sizes, pages
/// with cursors, matches searches by author, review request, state and update time, looks up
/// nodes by id, serves each PR's head commit's checks as captured in `probe/pr-checks.json`, and
/// bumps a PR's update time when it changes, though not when its checks do. Like its REST notifications, a
/// change to a PR notifies the viewer, who participates in every PR here, and a poll with
/// `If-Modified-Since` no older than the newest notification gets a 304. Tests can change PRs,
/// set the poll interval, refuse notifications, or make every GraphQL request fail.
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
    /// The ids of every lookup of PR rows by id, in order.
    private(set) var pullRequestLookups: [[String]] = []
    /// The ids of every lookup of PRs' checks, in order.
    private(set) var checksLookups: [[String]] = []
    /// When each PR's notification was last updated, by PR id.
    private var notified: [String: Date] = [:]
    /// What `X-Poll-Interval` says, or nil to leave it out.
    private var pollInterval: Int? = 60
    /// The status notifications are refused with, as for a token without access to them.
    private var notificationsRefusal: Int?
    /// The status of each notifications poll, in order.
    private(set) var notificationPolls: [Int] = []

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
        var all = probe.mine.nodes + toReview
        let checks = try JSONDecoder().decode(ChecksProbe.self, from: Data(contentsOf: projectRoot.appending(path: "probe/pr-checks.json"))).data.nodes
        for index in all.indices {
            let rollup = checks.first { $0?.id == all[index].id }??.commits.nodes.first?.commit.statusCheckRollup
            all[index].checkContexts = rollup?.contexts.nodes ?? []
        }
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

    nonisolated func notifications() -> GitHubNotifications {
        GitHubNotifications(token: { Self.validToken }, transport: self)
    }

    /// The open PRs a full load of `list` finds.
    func pullRequests(in list: PullRequestList) -> [FakePullRequest] {
        pullRequests.filter { $0.state == "OPEN" && matches($0, list) }
    }

    /// Changes the PR with `id`, which GitHub records as an update.
    func edit(_ id: String, _ change: @Sendable (inout FakePullRequest) throws -> Void) throws {
        let index = try #require(pullRequests.firstIndex { $0.id == id })
        let previous = updatedAt(pullRequests[index])
        try change(&pullRequests[index])
        // A second on from the last at least, as the update time is in whole seconds and a test's
        // changes come quicker than a person's.
        pullRequests[index].updatedAt = max(.now, previous + 1).formatted(.iso8601)
        // A second on from the last at least, so each change reaches a poll that saw the last;
        // HTTP dates are whole seconds.
        notified[id] = max(.now, (notified.values.max() ?? Self.quietSince) + 1)
    }

    /// Changes the checks on the head commit of the PR with `id`, which GitHub doesn't record as
    /// an update to the PR.
    func setChecks(of id: String, state: String, _ contexts: [FakeCheckContext]) throws {
        let index = try #require(pullRequests.firstIndex { $0.id == id })
        pullRequests[index].commits.nodes[0].commit.statusCheckRollup = .init(state: state)
        pullRequests[index].checkContexts = contexts
    }

    func setPollInterval(_ seconds: Int?) {
        pollInterval = seconds
    }

    func refuseNotifications(status: Int) {
        notificationsRefusal = status
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
        if url.path() == "/notifications" { return try notifications(request, url) }
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
        let response: any Encodable = if let ids = body.variables.ids, body.query.contains("contexts") {
            try checks(ids)
        } else if let ids = body.variables.ids, body.query.contains("reviewRequests") {
            try reviewRequests(ids)
        } else if let ids = body.variables.ids {
            try pullRequestRows(ids)
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
            nodes: results[start..<end].map { SearchNode(pullRequest: $0) }
        )))
    }

    private func notifications(_ request: URLRequest, _ url: URL) throws -> (Data, HTTPURLResponse) {
        let (body, response) = try notificationsResponse(request, url)
        notificationPolls.append(response.statusCode)
        return (body, response)
    }

    private func notificationsResponse(_ request: URLRequest, _ url: URL) throws -> (Data, HTTPURLResponse) {
        #expect(url.absoluteString == "https://api.github.com/notifications?participating=true")
        #expect(request.httpMethod == "GET", "only reads, so nothing is marked as read")
        var headers = pollInterval.map { ["X-Poll-Interval": String($0)] } ?? [:]
        guard request.value(forHTTPHeaderField: "Authorization") == "bearer \(Self.validToken)" else {
            return (Data(#"{"message":"Bad credentials"}"#.utf8), httpResponse(url, status: 401, headers: headers))
        }
        if let notificationsRefusal {
            let body = #"{"message":"Missing the 'notifications' scope.","documentation_url":"https://docs.github.com/rest/activity/notifications#list-notifications-for-the-authenticated-user","status":"403"}"#
            return (Data(body.utf8), httpResponse(url, status: notificationsRefusal, headers: headers))
        }
        // HTTP dates are whole seconds.
        let lastModified = Date(timeIntervalSince1970: (notified.values.max() ?? Self.quietSince).timeIntervalSince1970.rounded(.down))
        headers["Last-Modified"] = httpDate().string(from: lastModified)
        if let since = request.value(forHTTPHeaderField: "If-Modified-Since").flatMap(httpDate().date), lastModified <= since {
            return (Data(), httpResponse(url, status: 304, headers: headers))
        }
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/notifications.json")))
        let template = try #require((probe as? [[String: Any]])?.first)
        // Newest first, a page of 50.
        let threads = notified.sorted { $0.value > $1.value }.prefix(50).compactMap { id, date in
            pullRequests.first { $0.id == id }.map { notification(from: template, about: $0, at: date) }
        }
        return (try JSONSerialization.data(withJSONObject: threads), httpResponse(url, status: 200, headers: headers))
    }

    private func pullRequestRows(_ ids: [String]) throws -> Envelope<[String: [FakePullRequest?]]> {
        #expect(ids.count <= 100, "GitHub's nodes lookup takes at most 100 ids")
        pullRequestLookups.append(ids)
        return Envelope(data: ["nodes": ids.map { id in pullRequests.first { $0.id == id } }])
    }

    private func checks(_ ids: [String]) throws -> Envelope<ChecksPayload> {
        #expect(ids.count <= 100, "GitHub's nodes lookup takes at most 100 ids")
        checksLookups.append(ids)
        return Envelope(data: ChecksPayload(nodes: ids.map { id in
            pullRequests.first { $0.id == id }.map { pullRequest in
                let rollup = pullRequest.commits.nodes.first?.commit.statusCheckRollup.map { ChecksPayload.Rollup(state: $0.state, contexts: .init(nodes: pullRequest.checkContexts)) }
                return ChecksPayload.Node(id: id, commits: .init(nodes: [.init(commit: .init(statusCheckRollup: rollup))]))
            }
        }))
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
    var headRefOid: String
    var baseRefOid: String
    let author: Login?
    let repository: Repository
    var commits: Commits
    var commitCount: Count
    var comments: Count
    var reviewThreads: Count
    var requestedReviewers: [Reviewer] = []
    /// The head commit's checks, which only a lookup by id asks for.
    var checkContexts: [FakeCheckContext] = []

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
    struct Count: Codable, Sendable { var totalCount: Int }

    enum CodingKeys: String, CodingKey {
        case id, number, title, url, isDraft, state, mergedAt, closedAt, updatedAt, reviewDecision
        case headRefName, baseRefName, headRefOid, baseRefOid, author, repository, commits
        case commitCount, comments, reviewThreads
    }

    /// The probe's PRs predate asking for `state`, when they were all open, and for commit oids
    /// and counts, which are made up here.
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
        headRefOid = try container.decodeIfPresent(String.self, forKey: .headRefOid) ?? fakeOid("head \(id)")
        baseRefOid = try container.decodeIfPresent(String.self, forKey: .baseRefOid) ?? fakeOid("base \(id)")
        author = try container.decodeIfPresent(Login.self, forKey: .author)
        repository = try container.decode(Repository.self, forKey: .repository)
        commits = try container.decode(Commits.self, forKey: .commits)
        commitCount = try container.decodeIfPresent(Count.self, forKey: .commitCount) ?? Count(totalCount: 1)
        comments = try container.decodeIfPresent(Count.self, forKey: .comments) ?? Count(totalCount: 0)
        reviewThreads = try container.decodeIfPresent(Count.self, forKey: .reviewThreads) ?? Count(totalCount: 0)
    }
}

/// A status or check run in GitHub's JSON shape; a `StatusContext` sets `context` and `state`, a
/// `CheckRun` sets `name`, `status`, `conclusion` and `title`.
struct FakeCheckContext: Codable, Sendable {
    let __typename: String
    var name: String?
    var status: String?
    var conclusion: String?
    var title: String?
    var detailsUrl: String?
    var context: String?
    var state: String?
    var description: String?
    var targetUrl: String?

    static func status(_ context: String, _ state: String, description: String? = nil) -> FakeCheckContext {
        FakeCheckContext(__typename: "StatusContext", context: context, state: state, description: description)
    }

    static func checkRun(_ name: String, status: String, conclusion: String?, title: String? = nil) -> FakeCheckContext {
        FakeCheckContext(__typename: "CheckRun", name: name, status: status, conclusion: conclusion, title: title)
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

private func httpResponse(_ url: URL, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": "application/json"]) { $1 })!
}

extension FakeGitHub {
    /// When the viewer's newest notification was, before any PR changes.
    static let quietSince = Date(timeIntervalSince1970: 1_791_990_109)
}

/// The probe's notification moved onto `pullRequest`, as updated at `date`.
private func notification(from template: [String: Any], about pullRequest: FakePullRequest, at date: Date) -> [String: Any] {
    let name = pullRequest.repository.nameWithOwner
    let url = "https://api.github.com/repos/\(name)/pulls/\(pullRequest.number)"
    var thread = template
    thread["updated_at"] = date.formatted(.iso8601)
    var subject = template["subject"] as? [String: Any] ?? [:]
    subject["title"] = pullRequest.title
    subject["url"] = url
    subject["latest_comment_url"] = url
    thread["subject"] = subject
    var repository = template["repository"] as? [String: Any] ?? [:]
    repository["full_name"] = name
    repository["name"] = String(name.split(separator: "/").last ?? "")
    thread["repository"] = repository
    return thread
}

/// HTTP's date format, as in `Last-Modified: Wed, 14 Oct 2026 15:01:49 GMT`.
private func httpDate() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .gmt
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter
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

/// `probe/pr-checks.json`: the checks lookup's response for the PRs in `probe/pr-list.json`.
private struct ChecksProbe: Decodable {
    let data: ChecksPayload
}

private struct ChecksPayload: Codable {
    let nodes: [Node?]

    struct Node: Codable {
        let id: String
        let commits: Connection<CommitNode>
    }

    struct Connection<Element: Codable>: Codable { let nodes: [Element] }
    struct CommitNode: Codable { let commit: Commit }
    struct Commit: Codable { let statusCheckRollup: Rollup? }

    struct Rollup: Codable {
        let state: String
        let contexts: Connection<FakeCheckContext>
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
        let nodes: [SearchNode]
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

/// A PR as the app's search asks for it, without the counts it fetches only by id.
private struct SearchNode: Encodable {
    let pullRequest: FakePullRequest

    func encode(to encoder: any Encoder) throws {
        try pullRequest.encode(to: encoder)
        var container = encoder.container(keyedBy: FakePullRequest.CodingKeys.self)
        try container.encodeNil(forKey: .commitCount)
        try container.encodeNil(forKey: .comments)
        try container.encodeNil(forKey: .reviewThreads)
    }
}

/// A stable 40-hex-digit stand-in for a commit oid.
private func fakeOid(_ seed: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    let hex = String(hash, radix: 16)
    return String(repeating: "0", count: 40 - hex.count) + hex
}
