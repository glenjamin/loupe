import Foundation
import LoupeGitHub
import Testing

/// GitHub's conversations of PRs, each starting as the one captured in `probe/conversation.json`.
/// Like GitHub's GraphQL API it pages a PR's timeline with cursors at no more than the page size
/// asked for, answers a page after the first with the timeline alone, and has no node for a PR it
/// doesn't know. Tests can add comments, as when someone comments on GitHub, or make every
/// request fail.
actor FakeConversations {
    /// Each PR's conversation, less its timeline, in GitHub's JSON shape.
    private var nodes: [String: [String: Any]] = [:]
    private var timelines: [String: [[String: Any]]] = [:]
    private var failing = false
    /// How many timeline pages have been served, first pages included.
    private(set) var pagesServed = 0

    /// Gives the PR with `id` the probe's conversation.
    func add(_ id: String) throws {
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/conversation.json")))
        var node = try #require(((probe as? [String: Any])?["data"] as? [String: Any])?["node"] as? [String: Any])
        let timeline = try #require(node["timelineItems"] as? [String: Any])
        timelines[id] = try #require(timeline["nodes"] as? [[String: Any]])
        node["timelineItems"] = nil
        nodes[id] = node
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
}

/// The GitHub a PR's tab talks to: viewed files from `FakeViewedFiles`, conversations from
/// `FakeConversations`.
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
        return query.contains("timelineItems") ? try await conversations.send(request) : try await viewed.send(request)
    }
}

func fakeResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
}
