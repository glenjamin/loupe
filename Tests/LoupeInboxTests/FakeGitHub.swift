import Foundation
import LoupeGitHub
import LoupeModel
import Testing

/// An in-memory api.github.com holding the viewer's PRs, the PRs awaiting their review, and a
/// merged PR in neither list from `probe/pr-by-number.json`. Like GitHub's GraphQL API it
/// rejects requests without the expected token, caps page sizes, pages with cursors, matches
/// searches by author, review request, state and update time, looks up nodes by id and PRs by
/// repo and number with who their review is asked of, serves each PR's checks and mergeability
/// as captured in `probe/pr-status.json`,
/// and bumps a PR's update time when it changes, though not when its checks do. Like its REST notifications, a
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
    /// The merged PR in neither list, which new PRs are made from.
    private let unlistedPullRequest: FakePullRequest
    private let viewerTeams: Set<String>
    private let maxPageSize: Int
    private var failure: Failure?
    private(set) var requestCount = 0
    /// Every search string received, in order.
    private(set) var searches: [String] = []
    /// The ids of every lookup of PR rows by id, in order.
    private(set) var pullRequestLookups: [[String]] = []
    /// The ids of every lookup of PRs' statuses, in order.
    private(set) var statusLookups: [[String]] = []
    /// Every lookup of a PR by repo and number, as `owner/name#number`, in order.
    private(set) var numberLookups: [String] = []
    /// When each PR's notification was last updated, by PR id.
    private var notified: [String: Date] = [:]
    /// What `X-Poll-Interval` says, or nil to leave it out.
    private var pollInterval: Int? = 60
    /// The input of every `mergePullRequest` received, in order.
    private(set) var mergesReceived: [MergeInput] = []
    /// The PR id of every `markPullRequestReadyForReview` received, in order.
    private(set) var readyForReviewReceived: [String] = []
    /// The status notifications are refused with, as for a token without access to them.
    private var notificationsRefusal: Int?
    /// The status of each notifications poll, in order.
    private(set) var notificationPolls: [Int] = []

    /// Serves the PRs captured in a probe response, with review requested of the viewer on
    /// the to-review ones just now. The probe asked GitHub to sort by update time; `reversed`
    /// checks the app doesn't depend on that.
    init(fixture: String, reversed: Bool = false, maxPageSize: Int = 100, viewerTeams: Set<String> = []) throws {
        let data = try Data(contentsOf: projectRoot.appending(path: "probe/\(fixture)"))
        let probe = try JSONDecoder().decode(ProbeResponse.self, from: data).data
        var toReview = probe.toReview.nodes
        for index in toReview.indices {
            toReview[index].requestedReviewers = [.user(Self.viewer)]
            toReview[index].requestEvents = [.init(reviewer: .user(Self.viewer), createdAt: .now)]
        }
        var all = probe.mine.nodes + toReview
        let statuses = try JSONDecoder().decode(StatusProbe.self, from: Data(contentsOf: projectRoot.appending(path: "probe/pr-status.json"))).data.nodes
        for index in all.indices {
            let status = statuses.first { $0?.id == all[index].id } ?? nil
            all[index].checkContexts = status?.commits.nodes.first?.commit.statusCheckRollup?.contexts.nodes ?? []
            all[index].mergeable = status?.mergeable ?? "UNKNOWN"
            all[index].mergeStateStatus = status?.mergeStateStatus ?? "UNKNOWN"
        }
        pullRequests = reversed ? all.reversed() : all
        let unlisted = try Data(contentsOf: projectRoot.appending(path: "probe/pr-by-number.json"))
        unlistedPullRequest = try JSONDecoder().decode(NumberProbe.self, from: unlisted).data.repository.pullRequest
        pullRequests.append(unlistedPullRequest)
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

    /// Opens PR `number` by `author` in the unlisted PR's repo, asking `reviewers` to review it,
    /// as just made: in neither of the viewer's lists until their searches next ask.
    @discardableResult
    func openPullRequest(number: Int, by author: String, asking reviewers: [FakePullRequest.Reviewer] = []) throws -> FakePullRequest {
        var pullRequest = unlistedPullRequest
        pullRequest.id = "PR_new_\(number)"
        pullRequest.number = number
        pullRequest.url = "https://github.com/\(pullRequest.repository.nameWithOwner)/pull/\(number)"
        pullRequest.title = "New PR \(number)"
        pullRequest.author = .init(login: author)
        pullRequest.state = "OPEN"
        pullRequest.mergedAt = nil
        pullRequest.closedAt = nil
        pullRequest.reviewDecision = "REVIEW_REQUIRED"
        pullRequest.requestedReviewers = []
        pullRequest.requestEvents = []
        pullRequests.append(pullRequest)
        try edit(pullRequest.id) { _ in }
        for reviewer in reviewers {
            try requestReview(of: pullRequest.id, from: reviewer)
        }
        return try #require(pullRequests.first { $0.id == pullRequest.id })
    }

    /// Asks `reviewer` to review the PR with `id` at `date`, as a request or re-request, which
    /// GitHub records as an update.
    func requestReview(of id: String, from reviewer: FakePullRequest.Reviewer = .user(viewer), at date: Date = .now) throws {
        try edit(id) { pullRequest in
            pullRequest.requestEvents.append(.init(reviewer: reviewer, createdAt: date))
            if !pullRequest.requestedReviewers.contains(reviewer) { pullRequest.requestedReviewers.append(reviewer) }
        }
    }

    /// Makes `events` the whole history of review requests on the PR with `id`, as though made
    /// long ago and so not an update now.
    func setRequestEvents(of id: String, _ events: [FakePullRequest.RequestEvent]) throws {
        let index = try #require(pullRequests.firstIndex { $0.id == id })
        pullRequests[index].requestEvents = events
    }

    /// Gives each PR in the probe's review-request lookup the request history captured there.
    func replayRequestEvents(fromProbe name: String) throws {
        let probe = try JSONDecoder().decode(RequestsProbe.self, from: Data(contentsOf: projectRoot.appending(path: "probe/\(name)")))
        for node in probe.data.nodes {
            try setRequestEvents(of: node.id, try node.requestEvents.nodes.map { event in
                let reviewer: FakePullRequest.Reviewer = switch event.requestedReviewer.__typename {
                case "Team": .team(try #require(event.requestedReviewer.slug))
                default: .user(try #require(event.requestedReviewer.login))
                }
                return .init(reviewer: reviewer, createdAt: try Date(event.createdAt, strategy: .iso8601))
            })
        }
    }

    /// Changes the checks on the head commit of the PR with `id`, which GitHub doesn't record as
    /// an update to the PR.
    func setChecks(of id: String, state: String, _ contexts: [FakeCheckContext]) throws {
        let index = try #require(pullRequests.firstIndex { $0.id == id })
        pullRequests[index].commits.nodes[0].commit.statusCheckRollup = .init(state: state)
        pullRequests[index].checkContexts = contexts
    }

    /// Sets whether the PR with `id` merges cleanly and can be merged now, which GitHub works
    /// out in the background and doesn't record as an update to the PR.
    func setMergeState(of id: String, _ state: String, mergeable: String = "MERGEABLE") throws {
        let index = try #require(pullRequests.firstIndex { $0.id == id })
        pullRequests[index].mergeStateStatus = state
        pullRequests[index].mergeable = mergeable
    }

    /// The PR's head as GitHub has it now.
    func head(of id: String) throws -> String {
        try #require(pullRequests.first { $0.id == id }).headRefOid
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
        if body.query.contains("mergePullRequest(") {
            return (try mergePullRequest(try #require(body.variables.input)), httpResponse(url, status: 200))
        }
        if body.query.contains("markPullRequestReadyForReview(") {
            return (try markReadyForReview(try #require(body.variables.input).pullRequestId), httpResponse(url, status: 200))
        }
        let response: any Encodable = if let owner = body.variables.owner, let name = body.variables.name, let number = body.variables.number {
            pullRequest(in: "\(owner)/\(name)", number: number)
        } else if let ids = body.variables.ids, body.query.contains("contexts") {
            try statuses(ids)
        } else if let ids = body.variables.ids, body.query.contains("fragment PullRequestRow") {
            try pullRequestRows(ids)
        } else if let ids = body.variables.ids, body.query.contains("reviewRequests") {
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

    private func pullRequestRows(_ ids: [String]) throws -> Envelope<[String: [LookupNode?]]> {
        #expect(ids.count <= 100, "GitHub's nodes lookup takes at most 100 ids")
        pullRequestLookups.append(ids)
        return Envelope(data: ["nodes": ids.map { id in pullRequests.first { $0.id == id }.map(LookupNode.init) }])
    }

    /// As GitHub answers: a null repo when it has no PRs here, a null PR when none has that
    /// number, each with a `NOT_FOUND` error.
    private func pullRequest(in repository: String, number: Int) -> Envelope<[String: [String: LookupNode?]?]> {
        numberLookups.append("\(repository)#\(number)")
        let inRepository = pullRequests.filter { $0.repository.nameWithOwner.caseInsensitiveCompare(repository) == .orderedSame }
        guard !inRepository.isEmpty else {
            let error = Envelope<[String: [String: LookupNode?]?]>.GraphQLError(type: "NOT_FOUND", path: ["repository"], message: "Could not resolve to a Repository with the name '\(repository)'.")
            return Envelope(data: ["repository": nil], errors: [error])
        }
        guard let found = inRepository.first(where: { $0.number == number }) else {
            let error = Envelope<[String: [String: LookupNode?]?]>.GraphQLError(type: "NOT_FOUND", path: ["repository", "pullRequest"], message: "Could not resolve to a PullRequest with the number of \(number).")
            return Envelope(data: ["repository": ["pullRequest": nil]], errors: [error])
        }
        return Envelope(data: ["repository": ["pullRequest": LookupNode(pullRequest: found)]])
    }

    private func statuses(_ ids: [String]) throws -> Envelope<StatusPayload> {
        #expect(ids.count <= 100, "GitHub's nodes lookup takes at most 100 ids")
        statusLookups.append(ids)
        return Envelope(data: StatusPayload(nodes: ids.map { id in
            pullRequests.first { $0.id == id }.map { pullRequest in
                let rollup = pullRequest.commits.nodes.first?.commit.statusCheckRollup.map { StatusPayload.Rollup(state: $0.state, contexts: .init(nodes: pullRequest.checkContexts)) }
                return StatusPayload.Node(
                    id: id, mergeable: pullRequest.mergeable, mergeStateStatus: pullRequest.mergeStateStatus, reviewDecision: pullRequest.reviewDecision,
                    commits: .init(nodes: [.init(commit: .init(statusCheckRollup: rollup))])
                )
            }
        }))
    }

    /// Merges the PR as GitHub does, refusing as it does when the head has moved from the one
    /// expected or GitHub's merge box wouldn't allow it, in the shape of its `UNPROCESSABLE`
    /// errors.
    private func mergePullRequest(_ input: MergeInput) throws -> Data {
        mergesReceived.append(input)
        func refusal(_ type: String, _ message: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "data": ["mergePullRequest": NSNull()],
                "errors": [["type": type, "path": ["mergePullRequest"], "locations": [["line": 2, "column": 3]], "message": message]],
            ])
        }
        guard let pullRequest = pullRequests.first(where: { $0.id == input.pullRequestId }) else {
            return try refusal("NOT_FOUND", "Could not resolve to a node with the global id of '\(input.pullRequestId)'")
        }
        if let expected = input.expectedHeadOid, expected != pullRequest.headRefOid {
            return try refusal("UNPROCESSABLE", "Head branch was modified. Review and try the merge again.")
        }
        guard pullRequest.state == "OPEN", ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(pullRequest.mergeStateStatus) else {
            return try refusal("UNPROCESSABLE", "Pull Request is not mergeable")
        }
        try merge(input.pullRequestId)
        return try JSONSerialization.data(withJSONObject: ["data": ["mergePullRequest": ["pullRequest": ["id": input.pullRequestId, "state": "MERGED"]]]])
    }

    /// Takes the PR out of draft as GitHub does, which then works out afresh whether it can be
    /// merged, refusing a PR it can't find in the shape of its `NOT_FOUND` errors.
    private func markReadyForReview(_ id: String) throws -> Data {
        readyForReviewReceived.append(id)
        guard pullRequests.contains(where: { $0.id == id }) else {
            return try JSONSerialization.data(withJSONObject: [
                "data": ["markPullRequestReadyForReview": NSNull()],
                "errors": [["type": "NOT_FOUND", "path": ["markPullRequestReadyForReview"], "locations": [["line": 2, "column": 3]], "message": "Could not resolve to a node with the global id of '\(id)'"]],
            ])
        }
        try edit(id) {
            $0.isDraft = false
            $0.mergeStateStatus = "UNKNOWN"
        }
        return try JSONSerialization.data(withJSONObject: ["data": ["markPullRequestReadyForReview": ["pullRequest": ["id": id, "isDraft": false]]]])
    }

    private func viewer(_ query: String) throws -> Envelope<[String: [String: String]]> {
        #expect(query.contains("viewer { login }"))
        return Envelope(data: ["viewer": ["login": Self.viewer]])
    }

    private func reviewRequests(_ ids: [String]) throws -> Envelope<NodesPayload> {
        #expect(ids.count <= 100, "GitHub's nodes lookup takes at most 100 ids")
        let nodes = ids.map { id in
            pullRequests.first { $0.id == id }.map { pullRequest in
                NodesPayload.Node(id: id, state: pullRequest.state, reviewRequests: pullRequest.reviewRequestNodes, requestEvents: pullRequest.requestEventNodes)
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
    var id: String
    var number: Int
    var title: String
    var url: String
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
    var author: Login?
    let repository: Repository
    var commits: Commits
    var commitCount: Count
    var comments: Count
    var reviewThreads: Count
    var requestedReviewers: [Reviewer] = []
    /// Every request for review made on the PR, as its timeline records them.
    var requestEvents: [RequestEvent] = []
    /// The head commit's checks, whether it merges cleanly and whether it can be merged now,
    /// which only a lookup by id asks for.
    var checkContexts: [FakeCheckContext] = []
    var mergeable = "UNKNOWN"
    var mergeStateStatus = "UNKNOWN"

    enum Reviewer: Sendable, Equatable {
        case user(String)
        case team(String)
    }

    struct RequestEvent: Sendable {
        let reviewer: Reviewer
        let createdAt: Date
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
        // Only a lookup by id or number asks who the PR's review is asked of.
        let requests = try decoder.container(keyedBy: ReviewRequestKeys.self)
        requestedReviewers = try requests.decodeIfPresent(NodesPayload.Connection<NodesPayload.Request>.self, forKey: .reviewRequests)?.nodes
            .compactMap { $0.requestedReviewer.fake } ?? []
        requestEvents = try requests.decodeIfPresent(NodesPayload.Connection<NodesPayload.Event>.self, forKey: .requestEvents)?.nodes
            .compactMap { event in try event.requestedReviewer.fake.map { RequestEvent(reviewer: $0, createdAt: try Date(event.createdAt, strategy: .iso8601)) } } ?? []
    }
}

/// The fields only a lookup of a PR by id or number asks for, beside a search node's.
private enum ReviewRequestKeys: String, CodingKey {
    case reviewRequests, requestEvents
}

private extension FakePullRequest {
    var reviewRequestNodes: NodesPayload.Connection<NodesPayload.Request> {
        .init(nodes: requestedReviewers.map { .init(requestedReviewer: .init($0)) })
    }

    /// The last 20, oldest first, as GitHub returns them to the app's query.
    var requestEventNodes: NodesPayload.Connection<NodesPayload.Event> {
        .init(nodes: requestEvents.sorted { $0.createdAt < $1.createdAt }.suffix(20).map { event in
            .init(createdAt: event.createdAt.formatted(.iso8601), requestedReviewer: .init(event.reviewer))
        })
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

/// `probe/pr-by-number.json`: one PR looked up by repo and number.
private struct NumberProbe: Decodable {
    let data: Payload

    struct Payload: Decodable { let repository: Repository }
    struct Repository: Decodable { let pullRequest: FakePullRequest }
}

/// `probe/pr-status.json`: the status lookup's response for the PRs in `probe/pr-list.json`.
private struct StatusProbe: Decodable {
    let data: StatusPayload
}

private struct StatusPayload: Codable {
    let nodes: [Node?]

    /// The probe predates asking for the merge state and review decision.
    struct Node: Codable {
        let id: String
        let mergeable: String
        let mergeStateStatus: String?
        let reviewDecision: String?
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
        let input: MergeInput?
        let owner: String?
        let name: String?
        let number: Int?
    }
}

/// What a `mergePullRequest` asked for, or a `markPullRequestReadyForReview`, which gives
/// only the id.
struct MergeInput: Codable, Equatable {
    let pullRequestId: String
    let mergeMethod: String?
    let expectedHeadOid: String?
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
        let reviewRequests: Connection<Request>
        let requestEvents: Connection<Event>
    }

    struct Connection<Element: Codable>: Codable { let nodes: [Element] }
    struct Request: Codable { let requestedReviewer: Reviewer }

    struct Event: Codable {
        let createdAt: String
        let requestedReviewer: Reviewer
    }

    struct Reviewer: Codable {
        let __typename: String
        let login: String?
        let slug: String?

        init(_ reviewer: FakePullRequest.Reviewer) {
            switch reviewer {
            case let .user(login): self.init(__typename: "User", login: login, slug: nil)
            case let .team(slug): self.init(__typename: "Team", login: nil, slug: slug)
            }
        }

        init(__typename: String, login: String?, slug: String?) {
            self.__typename = __typename
            self.login = login
            self.slug = slug
        }

        /// Nil for a bot or anything else that's never the viewer.
        var fake: FakePullRequest.Reviewer? {
            switch __typename {
            case "User": login.map(FakePullRequest.Reviewer.user)
            case "Team": slug.map(FakePullRequest.Reviewer.team)
            default: nil
            }
        }
    }
}

/// `probe/review-requests.json`: the review-request lookup's response for some to-review PRs.
private struct RequestsProbe: Decodable {
    let data: Payload

    struct Payload: Decodable { let nodes: [Node] }

    struct Node: Decodable {
        let id: String
        let requestEvents: NodesPayload.Connection<NodesPayload.Event>
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

/// A PR as the app looks it up by id or number: a search node's fields, the counts, and who
/// its review is asked of.
private struct LookupNode: Encodable {
    let pullRequest: FakePullRequest

    func encode(to encoder: any Encoder) throws {
        try pullRequest.encode(to: encoder)
        var container = encoder.container(keyedBy: ReviewRequestKeys.self)
        try container.encode(pullRequest.reviewRequestNodes, forKey: .reviewRequests)
        try container.encode(pullRequest.requestEventNodes, forKey: .requestEvents)
    }
}

/// A stable 40-hex-digit stand-in for a commit oid.
private func fakeOid(_ seed: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    let hex = String(hash, radix: 16)
    return String(repeating: "0", count: 40 - hex.count) + hex
}
