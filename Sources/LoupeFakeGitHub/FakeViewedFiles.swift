import Foundation
import LoupeGitHub
import LoupeModel

/// GitHub's record of which files of each PR the viewer has viewed. Like GitHub's GraphQL API it
/// lists every file of a PR in pages of at most 100 with cursors, marks and unmarks files, and
/// refuses with GitHub's own error a path that isn't part of the PR. Tests can make every request
/// fail, or hold requests until released to see what shows meanwhile.
actor FakeViewedFiles: HTTPTransport {
    enum Mutation: Equatable {
        case mark(String)
        case unmark(String)
    }

    /// Each PR's files in GitHub's order, with their states.
    private var files: [String: [(path: String, state: FileViewedState)]] = [:]
    private(set) var mutations: [Mutation] = []
    private(set) var pagesServed = 0
    private var failing = false
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func client() -> GitHubClient {
        GitHubClient(token: { FakeGitHub.validToken }, transport: self)
    }

    func add(_ pullRequestId: String, files: [(String, FileViewedState)]) {
        self.files[pullRequestId] = files.map { (path: $0.0, state: $0.1) }
    }

    func state(of path: String, in pullRequestId: String) -> FileViewedState? {
        files[pullRequestId]?.first { $0.path == path }?.state
    }

    func change(_ path: String, in pullRequestId: String, to state: FileViewedState) throws {
        let index = try require(files[pullRequestId]?.firstIndex { $0.path == path })
        files[pullRequestId]?[index].state = state
    }

    func fail() { failing = true }
    func recover() { failing = false }

    func hold() { holding = true }

    func release() {
        holding = false
        held.forEach { $0.resume() }
        held = []
    }

    /// Returns once a request is being held.
    func waitForHeldRequest() async {
        if !held.isEmpty { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try require(request.url)
        try expect(url.absoluteString == "https://api.github.com/graphql")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)")
        if holding {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                heldWaiters.forEach { $0.resume() }
                heldWaiters = []
            }
        }
        if failing { return (Data(), response(url, status: 502)) }

        let data = try require(request.httpBody)
        let body = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try require(body["query"] as? String)
        let variables = try require(body["variables"] as? [String: Any])
        let payload: Any = if query.contains("markFileAsViewed") || query.contains("unmarkFileAsViewed") {
            try mutate(viewed: !query.contains("unmarkFileAsViewed"), variables)
        } else {
            try page(variables)
        }
        return (try JSONSerialization.data(withJSONObject: payload), response(url, status: 200))
    }

    private func page(_ variables: [String: Any]) throws -> Any {
        let id = try require(variables["id"] as? String)
        let first = try require(variables["first"] as? Int)
        try expect(first <= 100, "GitHub's maximum page size")
        let all = files[id] ?? []
        let start = try (variables["after"] as? String).map { try require(Int($0)) } ?? 0
        let end = min(start + first, all.count)
        pagesServed += 1
        let nodes = all[start..<end].map { ["path": $0.path, "viewerViewedState": $0.state.rawValue] }
        let pageInfo: [String: Any] = ["hasNextPage": end < all.count, "endCursor": String(end)]
        return ["data": ["node": ["files": ["pageInfo": pageInfo, "nodes": nodes]]]]
    }

    private func mutate(viewed: Bool, _ variables: [String: Any]) throws -> Any {
        let id = try require(variables["pullRequestId"] as? String)
        let path = try require(variables["path"] as? String)
        mutations.append(viewed ? .mark(path) : .unmark(path))
        guard let index = files[id]?.firstIndex(where: { $0.path == path }) else {
            let refusal = try Data(contentsOf: projectRoot.appending(path: "probe/viewed-mark-error.json"))
            return try JSONSerialization.jsonObject(with: refusal)
        }
        files[id]?[index].state = viewed ? .viewed : .unviewed
        let field = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        return ["data": [field: ["pullRequest": ["id": id]]]]
    }
}

private func response(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
}
