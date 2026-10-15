import Foundation
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ViewedFilesTests {
    @Test func openingAPullRequestTakesItsViewedFilesFromGitHubPagingPastVendoredOnes() async throws {
        let app = try await ViewedApp()
        let pullRequest = app.toReview[0]
        let vendored = (1...150).map { "vendor/lib/\($0).go" }
        await app.viewed.add(pullRequest.id, files: vendored.map { ($0, .viewed) } + [("app.go", .viewed), ("README", .dismissed), ("main.go", .unviewed)])

        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        #expect(await app.viewed.pagesServed == 2, "GitHub lists vendored files too, so the real ones can be on a later page")
        #expect(tab.viewedState(of: "app.go") == .viewed)
        #expect(tab.viewedState(of: "README") == .dismissed)
        #expect(tab.viewedState(of: "main.go") == .unviewed)
        #expect(tab.viewedState(of: "not/in/the/pr") == .unviewed)
        let stored = try app.store.viewedStates(of: pullRequest.id)
        #expect(stored.count == 153)
        #expect(stored["app.go"] == .viewed)

        // Next launch shows what was stored before GitHub answers, or if it can't.
        await app.viewed.fail()
        let nextRun = try #require(app.relaunch().tab(id: pullRequest.id))
        #expect(nextRun.viewedState(of: "app.go") == .viewed)
        await nextRun.load()
        #expect(nextRun.viewedState(of: "README") == .dismissed)
    }

    @Test func markingAFileViewedShowsAtOnceAndTellsGitHub() async throws {
        let app = try await ViewedApp()
        let pullRequest = app.toReview[0]
        await app.viewed.add(pullRequest.id, files: [("app.go", .unviewed), ("README", .unviewed)])
        let tab = try await app.open(pullRequest)

        await app.viewed.hold()
        let marking = Task { await tab.setViewed(true, path: "app.go") }
        await app.viewed.waitForHeldRequest()
        #expect(tab.viewedState(of: "app.go") == .viewed, "shown before GitHub answers")
        #expect(await app.viewed.state(of: "app.go", in: pullRequest.id) == .unviewed)

        await app.viewed.release()
        await marking.value
        #expect(await app.viewed.state(of: "app.go", in: pullRequest.id) == .viewed)
        #expect(try app.store.viewedStates(of: pullRequest.id)["app.go"] == .viewed)
        #expect(tab.viewedStateError == nil)

        await tab.toggleViewed(path: "app.go")
        #expect(tab.viewedState(of: "app.go") == .unviewed)
        #expect(await app.viewed.state(of: "app.go", in: pullRequest.id) == .unviewed)
        #expect(await app.viewed.mutations == [.mark("app.go"), .unmark("app.go")])
    }

    @Test func aChangeGitHubRefusesIsPutBack() async throws {
        let app = try await ViewedApp()
        let pullRequest = app.toReview[0]
        await app.viewed.add(pullRequest.id, files: [("app.go", .dismissed)])
        let tab = try await app.open(pullRequest)

        await app.viewed.fail()
        await tab.setViewed(true, path: "app.go")
        #expect(tab.viewedState(of: "app.go") == .dismissed)
        #expect(try #require(tab.viewedStateError).contains("app.go"))
        #expect(try app.store.viewedStates(of: pullRequest.id)["app.go"] == .dismissed)

        // GitHub refuses a path that isn't part of the PR, as when the diff is older than GitHub's.
        await app.viewed.recover()
        await tab.setViewed(true, path: "gone.go")
        #expect(tab.viewedState(of: "gone.go") == .unviewed)
        #expect(try #require(tab.viewedStateError).contains("Filepath must be part of pull request"))

        await tab.setViewed(true, path: "app.go")
        #expect(tab.viewedState(of: "app.go") == .viewed)
        #expect(tab.viewedStateError == nil, "cleared once a change goes through")
    }

    @Test func markingViewedAndAdvancingSkipsViewedFilesWrapsAndStopsWhenAllAreViewed() async throws {
        let repo = try await FakeRepository()
        let app = try await ViewedApp()
        let files = ["a.txt", "b.txt", "c.txt", "d.txt"]
        let pullRequest = try await app.pushPullRequest(changing: files, in: repo)
        await app.viewed.add(pullRequest.id, files: [("a.txt", .unviewed), ("b.txt", .viewed), ("c.txt", .dismissed), ("d.txt", .unviewed)])
        let tab = try await app.open(pullRequest)
        guard case let .ready(review) = tab.phase else { Issue.record("expected a diff, got \(tab.phase)"); return }
        #expect(review.changes.files.map(\.path) == files)
        #expect(tab.selectedFile == "a.txt")

        tab.selectedFile = "d.txt"
        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "a.txt", "wraps to the first not viewed")
        #expect(tab.viewedState(of: "d.txt") == .viewed)

        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "c.txt", "a file changed since it was viewed needs another look")
        #expect(!tab.allFilesViewed)

        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "c.txt", "none left, so it stays")
        #expect(tab.allFilesViewed)

        await tab.toggleViewed(path: "c.txt")
        #expect(tab.selectedFile == "c.txt", "unmarking stays on the file")
        #expect(!tab.allFilesViewed)
        #expect(await app.viewed.mutations == [.mark("d.txt"), .mark("a.txt"), .mark("c.txt"), .unmark("c.txt")])
    }

    @Test func movingOnPassesOverHiddenFilesWhichCanStillBeMarkedReviewed() async throws {
        let repo = try await FakeRepository()
        let app = try await ViewedApp()
        let pullRequest = try await app.pushPullRequest(changing: ["a.txt", "b.txt", "go.sum", "vendor/lib/lib.go"], in: repo)
        await app.viewed.add(pullRequest.id, files: [("a.txt", .unviewed), ("b.txt", .unviewed), ("go.sum", .unviewed), ("vendor/lib/lib.go", .unviewed)])
        let tab = try await app.open(pullRequest)

        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "b.txt")
        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "b.txt", "none left to review but hidden ones")
        #expect(tab.allFilesViewed)

        tab.selectedFile = "go.sum"
        await tab.toggleViewed(path: "go.sum")
        #expect(tab.viewedState(of: "go.sum") == .viewed)
        #expect(await app.viewed.state(of: "go.sum", in: pullRequest.id) == .viewed)
    }

    @Test func reloadingTakesViewedFilesFromGitHubAgain() async throws {
        let app = try await ViewedApp()
        let pullRequest = app.toReview[0]
        await app.viewed.add(pullRequest.id, files: [("app.go", .viewed)])
        let tab = try await app.open(pullRequest)

        // As when a push changes a viewed file.
        try await app.viewed.change("app.go", in: pullRequest.id, to: .dismissed)
        await tab.reload()

        #expect(tab.viewedState(of: "app.go") == .dismissed)
        #expect(try app.store.viewedStates(of: pullRequest.id)["app.go"] == .dismissed)
    }
}

/// The app's models over the PR fixture and an in-memory store, with viewed files kept by
/// `FakeViewedFiles`.
@MainActor
private struct ViewedApp {
    let github: FakeGitHub
    let viewed = FakeViewedFiles()
    let store: PullRequestStore
    let tabs: TabsModel

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        tabs = Self.tabs(github, viewed, store)
        await tabs.lists.refresh()
    }

    var toReview: [PullRequestSummary] {
        tabs.lists.pullRequests(in: .toReview)
    }

    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }

    /// Makes the first to-review PR one commit changing `paths` in `repo`, and returns it as
    /// the lists now have it.
    func pushPullRequest(changing paths: [String], in repo: FakeRepository) async throws -> PullRequestSummary {
        let listed = toReview[0]
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try await repo.switchTo("feature", creatingFrom: "main")
        let head = try await repo.commit(Dictionary(uniqueKeysWithValues: paths.map { ($0, "\($0)\n") }), message: "Add files")
        try await repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = head; $0.baseRefOid = branchPoint }
        await tabs.lists.refresh()
        return try #require(tabs.lists.pullRequest(id: listed.id))
    }

    /// Fresh models over the same store, as on the next launch.
    func relaunch() throws -> TabsModel {
        Self.tabs(github, viewed, store)
    }

    private static func tabs(_ github: FakeGitHub, _ viewed: FakeViewedFiles, _ store: PullRequestStore) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        return TabsModel(lists: lists, store: store, client: FakePullRequestDetails(viewed: viewed).client(), notifications: github.notifications())
    }
}

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
        let index = try #require(files[pullRequestId]?.firstIndex { $0.path == path })
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
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://api.github.com/graphql")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)")
        if holding {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                heldWaiters.forEach { $0.resume() }
                heldWaiters = []
            }
        }
        if failing { return (Data(), response(url, status: 502)) }

        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try #require(body["query"] as? String)
        let variables = try #require(body["variables"] as? [String: Any])
        let payload: Any = if query.contains("markFileAsViewed") || query.contains("unmarkFileAsViewed") {
            try mutate(viewed: !query.contains("unmarkFileAsViewed"), variables)
        } else {
            try page(variables)
        }
        return (try JSONSerialization.data(withJSONObject: payload), response(url, status: 200))
    }

    private func page(_ variables: [String: Any]) throws -> Any {
        let id = try #require(variables["id"] as? String)
        let first = try #require(variables["first"] as? Int)
        #expect(first <= 100, "GitHub's maximum page size")
        let all = files[id] ?? []
        let start = try (variables["after"] as? String).map { try #require(Int($0)) } ?? 0
        let end = min(start + first, all.count)
        pagesServed += 1
        let nodes = all[start..<end].map { ["path": $0.path, "viewerViewedState": $0.state.rawValue] }
        let pageInfo: [String: Any] = ["hasNextPage": end < all.count, "endCursor": String(end)]
        return ["data": ["node": ["files": ["pageInfo": pageInfo, "nodes": nodes]]]]
    }

    private func mutate(viewed: Bool, _ variables: [String: Any]) throws -> Any {
        let id = try #require(variables["pullRequestId"] as? String)
        let path = try #require(variables["path"] as? String)
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
