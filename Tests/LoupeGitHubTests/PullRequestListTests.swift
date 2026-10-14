import Foundation
import LoupeGitHub
import Testing

@MainActor
struct PullRequestListTests {
    @Test func showsBothColumnsNewestFirst() async throws {
        let github = try FakeGitHub(response: .fixture("pr-list.json", reversed: true))
        let model = PullRequestListModel(client: github.client(), onOpen: { _ in })

        await model.refresh()

        let lists = try #require(model.lists)
        #expect(model.error == nil)
        #expect(lists.mine.pullRequests.count == 50)
        #expect(lists.mine.totalCount == 110)
        #expect(lists.toReview.pullRequests.count == 13)
        for page in [lists.mine, lists.toReview] {
            let dates = page.pullRequests.map(\.updatedAt)
            #expect(dates == dates.sorted(by: >))
        }

        let newest = try #require(lists.toReview.pullRequests.first)
        #expect(newest.repository == "tamarinworks/atrium")
        #expect(newest.number == 2928)
        #expect(newest.author == "rowan-ashby")
        #expect(newest.reviewDecision == .reviewRequired)
        #expect(newest.checks == .success)
        #expect(newest.url == URL(string: "https://github.com/tamarinworks/atrium/pull/2928"))
    }

    @Test func keepsDraftsAndRowsWithoutReviewOrChecks() async throws {
        let github = try FakeGitHub(response: .fixture("pr-list.json"))
        let model = PullRequestListModel(client: github.client(), onOpen: { _ in })

        await model.refresh()

        let mine = try #require(model.lists?.mine.pullRequests)
        let draft = try #require(mine.first { $0.repository == "tamarinworks/gazette" && $0.number == 273 })
        #expect(draft.isDraft)
        #expect(draft.reviewDecision == nil)

        let unchecked = try #require(mine.first { $0.repository == "tamarinworks/hadley" && $0.number == 1 })
        #expect(unchecked.checks == nil)
        #expect(unchecked.reviewDecision == .approved)
    }

    @Test func aRejectedTokenShowsAnErrorInsteadOfLists() async throws {
        let github = try FakeGitHub(response: .fixture("pr-list.json"))
        let model = PullRequestListModel(client: github.client(token: "expired"), onOpen: { _ in })

        await model.refresh()

        #expect(model.lists == nil)
        #expect(model.error == "GitHub returned HTTP 401: Bad credentials")
    }

    @Test func aGraphQLErrorShowsAnErrorInsteadOfLists() async throws {
        let github = try FakeGitHub(response: .fixture("graphql-error.json"))
        let model = PullRequestListModel(client: github.client(), onOpen: { _ in })

        await model.refresh()

        #expect(model.lists == nil)
        #expect(model.error == "GitHub query failed: Field 'nonexistentField' doesn't exist on type 'User'")
    }

    @Test func aFailedRefreshDropsTheListsItCouldNotUpdate() async throws {
        let github = try FakeGitHub(response: .fixture("pr-list.json"))
        let model = PullRequestListModel(client: github.client(), onOpen: { _ in })
        await model.refresh()
        #expect(model.lists != nil)

        await github.respond(with: .status(502))
        await model.refresh()

        #expect(model.lists == nil)
        #expect(model.error == "GitHub returned HTTP 502")
    }

    @Test func aMissingGitHubLoginShowsAnError() async throws {
        let github = try FakeGitHub(response: .fixture("pr-list.json"))
        let client = github.client { throw GitHubError.token("not logged in to any GitHub hosts") }
        let model = PullRequestListModel(client: client, onOpen: { _ in })

        await model.refresh()

        #expect(model.lists == nil)
        #expect(model.error == "Couldn't get a GitHub token from `gh auth token`: not logged in to any GitHub hosts")
        #expect(await github.requestCount == 0)
    }

    @Test func refreshesPeriodicallyUntilCancelled() async throws {
        let github = try FakeGitHub(response: .fixture("pr-list.json"))
        let model = PullRequestListModel(client: github.client(), refreshInterval: .milliseconds(10), onOpen: { _ in })

        let refreshing = Task { await model.keepRefreshed() }
        defer { refreshing.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while await github.requestCount < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await github.requestCount >= 3)
        #expect(model.lists != nil)
    }

    @Test func openingAPullRequestHandsItToTheSelectionHandler() async throws {
        let github = try FakeGitHub(response: .fixture("pr-list.json"))
        var opened: [URL] = []
        let model = PullRequestListModel(client: github.client(), onOpen: { opened.append($0.url) })
        await model.refresh()

        let pullRequest = try #require(model.lists?.toReview.pullRequests.first)
        model.open(pullRequest)

        #expect(opened == [pullRequest.url])
    }
}

/// An in-memory api.github.com/graphql: rejects requests without the expected token, as GitHub
/// does, and otherwise answers with whatever response the test has set.
actor FakeGitHub: HTTPTransport {
    enum Response {
        case body(Data)
        case status(Int)

        static func fixture(_ name: String, reversed: Bool = false) throws -> Response {
            let data = try Data(contentsOf: projectRoot.appending(path: "probe/\(name)"))
            return .body(reversed ? try reversingSearchResults(data) : data)
        }
    }

    static let validToken = "test-token"

    private var response: Response
    private(set) var requestCount = 0

    init(response: Response) {
        self.response = response
    }

    nonisolated func client(token: String = validToken) -> GitHubClient {
        client { token }
    }

    nonisolated func client(token: @escaping GitHubClient.TokenProvider) -> GitHubClient {
        GitHubClient(token: token, transport: self)
    }

    func respond(with response: Response) {
        self.response = response
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
        switch response {
        case let .body(data): return (data, httpResponse(url, status: 200))
        case let .status(status): return (Data(), httpResponse(url, status: status))
        }
    }
}

let projectRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func httpResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
}

/// The probe asked GitHub to sort by update time; reversing each search's nodes checks the app
/// doesn't depend on that.
private func reversingSearchResults(_ data: Data) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var searches = root["data"] as? [String: [String: Any]]
    else { throw CocoaError(.coderReadCorrupt) }
    for (alias, var search) in searches {
        search["nodes"] = (search["nodes"] as? [Any]).map { Array($0.reversed()) }
        searches[alias] = search
    }
    root["data"] = searches
    return try JSONSerialization.data(withJSONObject: root)
}
