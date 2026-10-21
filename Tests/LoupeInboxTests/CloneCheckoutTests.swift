import Foundation
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct CloneCheckoutTests {
    @Test func cloningARepoWithNoCheckoutStoresItAndShowsTheDiff() async throws {
        let repo = try await FakeRepository()
        let app = try await CloneApp(serving: repo)
        let tab = try await app.openPushedPullRequest(in: repo)
        guard case .noCheckout = tab.phase else { Issue.record("expected no checkout, got \(tab.phase)"); return }
        let repository = tab.pullRequest.repository
        let destination = app.ownersRoot.appending(path: repositoryName(repository), directoryHint: .isDirectory)
        #expect(tab.cloneDestination == destination)

        await tab.cloneCheckout()

        guard case let .ready(review) = tab.phase else { Issue.record("expected the diff, got \(tab.phase)"); return }
        #expect(review.changes.files.map(\.path) == ["app.go"])
        #expect(tab.checkoutClone == nil)
        #expect(try app.store.localRepos(for: [repository])[repository]?.path.path(percentEncoded: false) == destination.path(percentEncoded: false))
        // As configured, not as the test's rewrite of github.com has it.
        #expect(try await runGit(["config", "remote.origin.url"], in: destination) == "https://github.com/\(repository)")
        #expect(try app.entries(of: app.ownersRoot) == [repositoryName(repository)], "nothing but the clone is left behind")
    }

    @Test func aFailedCloneSaysWhyAndLeavesNothingBehind() async throws {
        let repo = try await FakeRepository()
        let app = try await CloneApp(serving: repo)
        let tab = try await app.openPushedPullRequest(in: repo, served: false)

        await tab.cloneCheckout()

        guard case let .failed(message)? = tab.checkoutClone else { Issue.record("expected a failure, got \(String(describing: tab.checkoutClone))"); return }
        #expect(message.hasPrefix("fatal:"))
        #expect(message.contains("\(tab.pullRequest.repository)' does not appear to be a git repository"))
        guard case .noCheckout = tab.phase else { Issue.record("expected no checkout, got \(tab.phase)"); return }
        #expect(try app.entries(of: app.ownersRoot).isEmpty)
        #expect(try app.store.localRepos(for: [tab.pullRequest.repository]).isEmpty)
    }

    @Test func anExistingDirectoryOfTheRepositorysNameIsLeftAlone() async throws {
        let repo = try await FakeRepository()
        let app = try await CloneApp(serving: repo)
        let tab = try await app.openPushedPullRequest(in: repo)
        let destination = try #require(tab.cloneDestination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let notes = destination.appending(path: "notes.txt")
        try "Mine.\n".write(to: notes, atomically: true, encoding: .utf8)

        await tab.cloneCheckout()

        guard case let .failed(message)? = tab.checkoutClone else { Issue.record("expected a failure, got \(String(describing: tab.checkoutClone))"); return }
        #expect(message.contains("already exists"))
        #expect(try String(contentsOf: notes, encoding: .utf8) == "Mine.\n")
        #expect(try app.entries(of: destination) == ["notes.txt"])
        #expect(try app.entries(of: app.ownersRoot) == [destination.lastPathComponent])
        guard case .noCheckout = tab.phase else { Issue.record("expected no checkout, got \(tab.phase)"); return }
    }

    @Test func cancellingACloneUnderwayStopsGitAndLeavesNothingBehind() async throws {
        let repo = try await FakeRepository()
        // github.com answers nothing, so the clone waits until it's cancelled.
        let app = try await CloneApp(serving: repo, cloneConfig: [
            "protocol.ext.allow": "always",
            "url.ext::sh -c exec% sleep% 60% 2>/dev/null .insteadOf": "https://github.com/",
        ])
        let tab = try await app.openPushedPullRequest(in: repo)
        let cloning = Task { await tab.cloneCheckout() }
        try await until {
            if case .cloning(progress: _?)? = tab.checkoutClone { true } else { false }
        }

        let cancelledAt = ContinuousClock.now
        tab.cancelClone()
        await cloning.value

        #expect(ContinuousClock.now - cancelledAt < .seconds(30), "git is stopped rather than waited out")
        #expect(tab.checkoutClone == nil)
        guard case .noCheckout = tab.phase else { Issue.record("expected no checkout, got \(tab.phase)"); return }
        #expect(try app.entries(of: app.ownersRoot).isEmpty)
        #expect(try app.store.localRepos(for: [tab.pullRequest.repository]).isEmpty)
    }
}

/// The app's models over the PR fixture, with two search roots in a temp directory, the first
/// named after the fixture's owner and the other `GitHub`, and none holding a checkout. Clones
/// fetch github.com from a directory serving `repo` under the PR's repo's name, once served.
@MainActor
private final class CloneApp {
    let github: FakeGitHub
    let details = FakePullRequestDetails()
    let store: PullRequestStore
    let tabs: TabsModel
    let root: URL
    let ownersRoot: URL
    private let served: URL
    private let repo: FakeRepository

    init(serving repo: FakeRepository, cloneConfig: [String: String]? = nil) async throws {
        self.repo = repo
        root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory).resolvingSymlinksInPath()
        served = root.appending(path: "github.com", directoryHint: .isDirectory)
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        let probe = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        await probe.refresh()
        let owner = try #require(probe.pullRequests(in: .toReview).first?.repository.split(separator: "/").first)
        ownersRoot = root.appending(path: String(owner), directoryHint: .isDirectory)
        let others = root.appending(path: "GitHub", directoryHint: .isDirectory)
        for directory in [ownersRoot, others, served] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let config = cloneConfig ?? ["url.\(served.path(percentEncoded: false)).insteadOf": "https://github.com/"]
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [ownersRoot, others], cloneConfig: config, onOpen: { _ in })
        tabs = .manuallyTimed(lists: lists, store: store, client: details.client(), notifications: github.notifications())
        await lists.refresh()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Opens the first to-review PR, pushed to `repo` with one commit, once it has tried to
    /// diff it; `served` says whether github.com has the repo for a clone to fetch.
    func openPushedPullRequest(in repo: FakeRepository, served isServed: Bool = true) async throws -> PullRequestTab {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        try await details.conversations.add(listed.id)
        if isServed {
            let link = served.appending(path: listed.repository)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.origin)
        }
        let branchPoint = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try await repo.switchTo("feature", creatingFrom: "main")
        let commit = try await repo.commit([
            "app.go": "package app\n\nfunc Hello() string { return \"hi\" }\n",
            "vendor/example.com/lib/lib.go": "package lib // bumped\n",
        ], message: "Say hi")
        try await repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = commit; $0.baseRefOid = branchPoint }
        await tabs.lists.refresh()
        let pullRequest = try #require(tabs.lists.pullRequest(id: listed.id))
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }

    /// The names in `directory`, hidden ones included, sorted.
    func entries(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
    }
}

private func repositoryName(_ repository: String) -> String {
    repository.split(separator: "/").last.map(String.init) ?? repository
}
