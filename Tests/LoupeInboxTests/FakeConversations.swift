import Foundation
import LoupeGitHub
import Testing

/// GitHub's conversations of PRs, each starting as the one captured in `probe/conversation.json`.
/// Like GitHub's GraphQL API it pages a PR's timeline with cursors at no more than the page size
/// asked for, answers a page after the first with the timeline alone, and has no node for a PR it
/// doesn't know. Its repos' people and teams are those in `probe/reviewer-candidates.json`, which
/// it searches by login or name; asking them to review adds them to a PR's review requests, and
/// asking anyone it doesn't know is refused, as GitHub refuses an id it can't resolve. Tests can
/// add comments and reviews or ask for reviews, as people do on GitHub, hide the teams, as from a
/// token without access to them, or make every request fail.
actor FakeConversations {
    /// Each PR's conversation, less its timeline, in GitHub's JSON shape.
    private var nodes: [String: [String: Any]] = [:]
    private var timelines: [String: [[String: Any]]] = [:]
    private var failing = false
    private var teamsHidden = false
    /// How many timeline pages have been served, first pages included.
    private(set) var pagesServed = 0
    /// The input of every `requestReviews` received, in order.
    private(set) var reviewRequestsReceived: [ReviewRequestInput] = []
    private var users: [[String: Any]] = []
    private var teams: [[String: Any]] = []

    struct ReviewRequestInput: Equatable {
        let pullRequestId: String
        let userIds: [String]
        let teamIds: [String]
        let union: Bool
    }

    /// Gives the PR with `id` the probe's conversation.
    func add(_ id: String) throws {
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/conversation.json")))
        var node = try #require(((probe as? [String: Any])?["data"] as? [String: Any])?["node"] as? [String: Any])
        let timeline = try #require(node["timelineItems"] as? [String: Any])
        timelines[id] = try #require(timeline["nodes"] as? [[String: Any]])
        node["timelineItems"] = nil
        nodes[id] = node
        try loadPeople()
    }

    /// Adds a comment to the end of the PR's timeline.
    func comment(_ bodyHTML: String, on id: String, by login: String = "octocat") {
        let index = timelines[id, default: []].count
        timelines[id, default: []].append([
            "__typename": "IssueComment",
            "id": "IC_fake_\(index)",
            "bodyHTML": bodyHTML,
            "createdAt": Date.now.formatted(.iso8601),
            "isMinimized": false,
            "author": ["login": login, "avatarUrl": "https://avatars.githubusercontent.com/u/583231?v=4"],
        ])
    }

    /// Submits a review of the PR by the user with `login`, which becomes their latest and
    /// answers any request of them, as on GitHub.
    func review(_ state: String, by login: String, on id: String) throws {
        let user = try self.user(login)
        var node = try #require(nodes[id])
        var reviews = ((node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        reviews.removeAll { ($0["author"] as? [String: Any])?["login"] as? String == login }
        reviews.append(["state": state, "submittedAt": Date.now.formatted(.iso8601), "author": user])
        node["latestReviews"] = ["nodes": reviews]
        let requests = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        node["reviewRequests"] = ["nodes": requests.filter { ($0["requestedReviewer"] as? [String: Any])?["login"] as? String != login }]
        nodes[id] = node
    }

    /// Asks the user with `login` to review, as from github.com.
    func request(_ login: String, on id: String) throws {
        try addRequest(user(login), on: id)
    }

    func hideTeams() { teamsHidden = true }

    func timelineCount(of id: String) -> Int {
        timelines[id]?.count ?? 0
    }

    func fail() { failing = true }
    func recover() { failing = false }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://api.github.com/graphql")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)")
        if failing { return (Data(), fakeResponse(url, status: 502)) }
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try #require(body["query"] as? String)
        let variables = try #require(body["variables"] as? [String: Any])
        if query.contains("requestReviews(") { return try requestReviews(variables, url) }
        if query.contains("assignableUsers(") { return try searchUsers(query, variables, url) }
        if query.contains("teams(") { return try searchTeams(variables, url) }
        let id = try #require(variables["id"] as? String)
        guard var node = nodes[id], let timeline = timelines[id] else {
            return (try JSONSerialization.data(withJSONObject: ["data": ["node": NSNull()]]), fakeResponse(url, status: 200))
        }
        let first = try #require(query.firstMatch(of: /timelineItems\(first: (\d+)/).flatMap { Int($0.1) })
        #expect(first <= 100, "GitHub's maximum page size")
        let start = try (variables["after"] as? String).map { try #require(Int($0)) } ?? 0
        let end = min(start + first, timeline.count)
        pagesServed += 1
        let page: [String: Any] = [
            "pageInfo": ["hasNextPage": end < timeline.count, "endCursor": end > start ? String(end) as Any : NSNull()],
            "nodes": Array(timeline[start..<end]),
        ]
        if query.contains("reviewThreads") {
            node["timelineItems"] = page
        } else {
            node = ["timelineItems": page]
        }
        return (try JSONSerialization.data(withJSONObject: ["data": ["node": node]]), fakeResponse(url, status: 200))
    }

    private func requestReviews(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try #require(variables["input"] as? [String: Any])
        let id = try #require(input["pullRequestId"] as? String)
        let userIds = input["userIds"] as? [String] ?? []
        let teamIds = input["teamIds"] as? [String] ?? []
        reviewRequestsReceived.append(ReviewRequestInput(pullRequestId: id, userIds: userIds, teamIds: teamIds, union: input["union"] as? Bool ?? false))
        guard nodes[id] != nil else { return try refusal(unresolved: id, url) }
        var asked: [[String: Any]] = []
        for userId in userIds {
            guard let user = users.first(where: { $0["id"] as? String == userId }) else { return try refusal(unresolved: userId, url) }
            asked.append(user)
        }
        for teamId in teamIds {
            guard let team = teams.first(where: { $0["id"] as? String == teamId }) else { return try refusal(unresolved: teamId, url) }
            asked.append(["__typename": "Team", "id": teamId, "teamName": team["name"] ?? "", "combinedSlug": team["combinedSlug"] ?? ""])
        }
        for reviewer in asked {
            try addRequest(reviewer, on: id)
        }
        return (try JSONSerialization.data(withJSONObject: ["data": ["requestReviews": ["clientMutationId": NSNull()]]]), fakeResponse(url, status: 200))
    }

    private func searchUsers(_ query: String, _ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let text = try #require(variables["text"] as? String)
        let first = try #require(query.firstMatch(of: /assignableUsers\(first: (\d+)/).flatMap { Int($0.1) })
        #expect(first <= 100, "GitHub's maximum page size")
        let matching = users.filter { matches(text, $0["login"], $0["name"]) }.prefix(first).map {
            $0.filter { $0.key != "__typename" }
        }
        let repository: [String: Any] = ["assignableUsers": ["nodes": Array(matching)]]
        return (try JSONSerialization.data(withJSONObject: ["data": ["repository": repository]]), fakeResponse(url, status: 200))
    }

    private func searchTeams(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let text = try #require(variables["text"] as? String)
        if teamsHidden {
            let body: [String: Any] = [
                "data": ["repository": ["owner": ["teams": NSNull()]]],
                "errors": [["type": "FORBIDDEN", "path": ["repository", "owner", "teams"], "message": "Resource not accessible by personal access token"]],
            ]
            return (try JSONSerialization.data(withJSONObject: body), fakeResponse(url, status: 200))
        }
        let matching = teams.filter { matches(text, $0["name"], $0["combinedSlug"]) }
        let repository: [String: Any] = ["owner": ["teams": ["nodes": matching]]]
        return (try JSONSerialization.data(withJSONObject: ["data": ["repository": repository]]), fakeResponse(url, status: 200))
    }

    /// GitHub keeps one request per reviewer, so asking again leaves the one there.
    private func addRequest(_ reviewer: [String: Any], on id: String) throws {
        var node = try #require(nodes[id])
        var requests = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let reviewerId = reviewer["id"] as? String
        if !requests.contains(where: { ($0["requestedReviewer"] as? [String: Any])?["id"] as? String == reviewerId }) {
            requests.append(["requestedReviewer": reviewer])
        }
        node["reviewRequests"] = ["nodes": requests]
        nodes[id] = node
    }

    /// The user with `login`, shaped as the conversation query's `Reviewer` fragment returns them.
    private func user(_ login: String) throws -> [String: Any] {
        try #require(users.first { $0["login"] as? String == login })
    }

    private func loadPeople() throws {
        guard users.isEmpty else { return }
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/reviewer-candidates.json")))
        let repository = try #require(((probe as? [String: Any])?["data"] as? [String: Any])?["repository"] as? [String: Any])
        let assignable = try #require((repository["assignableUsers"] as? [String: Any])?["nodes"] as? [[String: Any]])
        users = assignable.map { $0.merging(["__typename": "User"]) { $1 } }
        teams = try #require(((repository["owner"] as? [String: Any])?["teams"] as? [String: Any])?["nodes"] as? [[String: Any]])
    }

    /// GitHub's shape for a mutation refused over an id it can't resolve, as in
    /// `probe/viewed-mark-error.json`.
    private func refusal(unresolved id: String, _ url: URL) throws -> (Data, HTTPURLResponse) {
        let body: [String: Any] = [
            "data": ["requestReviews": NSNull()],
            "errors": [[
                "type": "NOT_FOUND",
                "path": ["requestReviews"],
                "locations": [["line": 2, "column": 3]],
                "message": "Could not resolve to a node with the global id of '\(id)'",
            ]],
        ]
        return (try JSONSerialization.data(withJSONObject: body), fakeResponse(url, status: 200))
    }
}

/// The GitHub a PR's tab talks to: viewed files from `FakeViewedFiles`, conversations and
/// reviewers from `FakeConversations`, signed in as `FakeGitHub.viewer`.
struct FakePullRequestDetails: HTTPTransport {
    var viewed = FakeViewedFiles()
    var conversations = FakeConversations()

    func client() -> GitHubClient {
        GitHubClient(token: { FakeGitHub.validToken }, transport: self)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try #require(body["query"] as? String)
        if query.contains("viewer { login }") {
            let url = try #require(request.url)
            return (try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["login": FakeGitHub.viewer]]]), fakeResponse(url, status: 200))
        }
        let isConversation = ["timelineItems", "requestReviews(", "assignableUsers(", "teams("].contains { query.contains($0) }
        return isConversation ? try await conversations.send(request) : try await viewed.send(request)
    }
}

func fakeResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
}

/// Whether any of `fields` contains `text`, ignoring case, as GitHub's searches of people and
/// teams match; empty text matches everyone.
private func matches(_ text: String, _ fields: Any?...) -> Bool {
    text.isEmpty || fields.contains { ($0 as? String)?.localizedCaseInsensitiveContains(text) == true }
}
