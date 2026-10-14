import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct TabsTests {
    @Test func choosingAPullRequestOpensItOrFocusesItWhenAlreadyOpen() async throws {
        let app = try await App()
        let (first, second) = (app.toReview[0], app.toReview[1])

        app.tabs.lists.open(first)
        app.tabs.lists.open(second)
        #expect(app.tabs.tabs.map(\.id) == [first.id, second.id])
        #expect(app.tabs.selected == second.id)

        app.tabs.lists.open(first)
        #expect(app.tabs.tabs.map(\.id) == [first.id, second.id], "not opened twice")
        #expect(app.tabs.selected == first.id)
        #expect(app.shown == [first.id, second.id, first.id], "its window is brought forward each time")
        #expect(app.tabs.tab(id: first.id)?.title == "\(first.repository.split(separator: "/").last!) #\(first.number)")
    }

    @Test func closingAPullRequestsWindowForgetsItForNextLaunch() async throws {
        let app = try await App()
        let (kept, closed) = (app.toReview[0], app.toReview[1])
        app.tabs.open(kept)
        app.tabs.open(closed)

        app.tabs.close(closed.id)
        #expect(app.tabs.tabs.map(\.id) == [kept.id])
        #expect(app.tabs.selected == nil, "the closed one was frontmost")

        let nextRun = try app.relaunch()
        #expect(nextRun.tabs.map(\.id) == [kept.id])
        #expect(nextRun.selected == nil)
    }

    @Test func openPullRequestsAndTheFrontmostComeBackNextLaunchEvenWhenNoLongerListed() async throws {
        let app = try await App()
        let (kept, reviewed) = (app.toReview[0], app.toReview[1])
        app.tabs.open(kept)
        app.tabs.open(reviewed)
        app.tabs.select(kept.id)
        // Reviewing a PR takes it out of the to-review list.
        try await app.github.edit(reviewed.id) { $0.requestedReviewers = [] }
        await app.tabs.lists.refresh()
        #expect(app.tabs.lists.pullRequest(id: reviewed.id) == nil)

        let nextRun = try app.relaunch()

        #expect(nextRun.tabs.map(\.id) == [kept.id, reviewed.id])
        #expect(nextRun.selected == kept.id)
        #expect(nextRun.tabs[1].pullRequest.title == reviewed.title)

        nextRun.select(nil)
        #expect(try app.relaunch().selected == nil, "the lists were frontmost")
    }

    @Test func aTabDiffsThePullRequestFromItsCheckoutAndOffersANewHeadAsAReload() async throws {
        let repo = try FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let branchPoint = try #require(pullRequest.baseRefOid)

        let review = try #require(tab.ready)
        #expect(review.headOid == first)
        #expect(review.mergeBase == branchPoint)
        #expect(review.files.map(\.path) == ["app.go"])
        #expect(review.hiddenCount == 2, "vendor/ by git, yarn.lock by the path filter")
        #expect(tab.selectedFile == "app.go")
        #expect(tab.pendingChange == nil)
        let recorded = try #require(try app.store.diffRecord(for: pullRequest.id))
        #expect(recorded.headRefOid == first)

        // Showing the tab again doesn't redo the work.
        await tab.load()
        #expect(try app.store.diffRecord(for: pullRequest.id) == recorded)

        // A refresh bringing a new head offers it, rather than replacing the diff being read.
        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        await app.tabs.lists.refresh()
        await tab.load()
        #expect(tab.pendingChange == .newCommits)
        #expect(tab.ready?.headOid == first)

        await tab.reload()

        #expect(tab.pendingChange == nil)
        #expect(tab.ready?.headOid == second)
        #expect(tab.ready?.files.map(\.path) == ["README", "app.go"])
        #expect(tab.selectedFile == "app.go", "the shown file stays shown")
    }

    @Test func anUnchangedNotificationsPollChecksNothingAndWaitsAsLongAsGitHubAsks() async throws {
        let app = try await App()
        let (opened, other) = (app.toReview[0], app.toReview[1])
        app.tabs.open(opened)
        await app.github.setPollInterval(90)

        #expect(await app.tabs.watchForChanges() == .seconds(90))
        try await app.github.edit(other.id) { $0.title = "Renamed" }
        #expect(await app.tabs.watchForChanges() == .seconds(90), "a notification about a PR that isn't open")
        let before = app.tabs.lists.pullRequests(in: .toReview)

        #expect(await app.tabs.watchForChanges() == .seconds(90), "nothing new: a 304")

        #expect(await app.github.notificationPolls == [200, 200, 304])
        #expect(await app.github.pullRequestLookups.isEmpty)
        #expect(app.tabs.lists.pullRequests(in: .toReview) == before)
        #expect(app.tabs.changeSignal == .notifications)

        await app.github.setPollInterval(nil)
        #expect(await app.tabs.watchForChanges() == .seconds(60), "GitHub's documented default")
    }

    @Test func aNotificationAboutAnOpenPullRequestOffersItsNewCommitsWithoutReplacingTheDiff() async throws {
        let repo = try FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == nil, "the notification about the PR's last change finds nothing new")

        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        _ = await app.tabs.watchForChanges()

        #expect(await app.github.pullRequestLookups.last == [pullRequest.id])
        #expect(tab.pullRequest.headRefOid == second)
        #expect(tab.pendingChange == .newCommits)
        #expect(tab.ready?.headOid == first, "the diff being read stays")
        #expect(tab.selectedFile == "app.go")

        await tab.reload()

        #expect(tab.pendingChange == nil)
        #expect(tab.ready?.headOid == second)
    }

    @Test func otherActivityIsOfferedAsAnUpdateUntilDismissed() async throws {
        let repo = try FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)

        try await app.github.edit(pullRequest.id) { $0.comments.totalCount += 1 }
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == .updated)

        tab.dismissPendingChange()
        #expect(tab.pendingChange == nil)
        #expect(tab.ready?.headOid == first)
        await app.tabs.lists.refresh()
        #expect(tab.pendingChange == nil, "the lists' searches, which lack the counts, change nothing")
        #expect(tab.pullRequest.commentCount == 1)

        try await app.github.edit(pullRequest.id) { $0.reviewDecision = "APPROVED" }
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == .updated, "a later change is offered again")
    }

    @Test func refusedNotificationsFallBackToCheckingOpenPullRequestsOnATimer() async throws {
        let repo = try FakeRepository()
        let app = try await App()
        let (pullRequest, tab, _) = try await app.openDiffed(in: repo)
        await app.github.refuseNotifications(status: 403)

        #expect(await app.tabs.watchForChanges() == App.fallbackInterval)
        #expect(app.tabs.changeSignal == .timer)
        #expect(await app.github.pullRequestLookups == [[pullRequest.id]])
        #expect(app.tabs.lists.error == nil)
        #expect(tab.pendingChange == nil)
        #expect(tab.ready != nil)

        _ = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        #expect(await app.tabs.watchForChanges() == App.fallbackInterval)

        #expect(await app.github.notificationPolls == [403], "not asked again")
        #expect(tab.pendingChange == .newCommits)
    }

    @Test func aTabWithoutACheckoutSaysSoAndAGitFailureShowsGitsMessage() async throws {
        let repo = try FakeRepository()
        let app = try await App()
        let pullRequest = app.toReview[0]
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))

        await tab.load()
        guard case .noCheckout = tab.phase else { Issue.record("expected no checkout, got \(tab.phase)"); return }

        // A checkout is known now, but the PR was never pushed to its origin.
        try await app.store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: pullRequest.repository, path: repo.checkout, verifiedAt: .now)])
        await tab.load()
        guard case let .failed(message) = tab.phase else { Issue.record("expected a failure, got \(tab.phase)"); return }
        #expect(message.contains("refs/pull/\(pullRequest.number)/head"))
    }
}

/// The app's models over the PR fixture and an in-memory store, searching no directories for
/// checkouts.
@MainActor
private struct App {
    let github: FakeGitHub
    let store: PullRequestStore
    let tabs: TabsModel
    /// The PRs whose windows the app was asked to bring forward, in order.
    private let showRecorder = ShowRecorder()

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        tabs = Self.tabs(github, store)
        tabs.show = { [showRecorder] in showRecorder.ids.append($0) }
        await tabs.lists.refresh()
    }

    var shown: [String] {
        showRecorder.ids
    }

    var toReview: [PullRequestSummary] {
        tabs.lists.pullRequests(in: .toReview)
    }

    /// Opens the first to-review PR, pushed to `repo` with one commit, once its diff is ready.
    /// Returns the PR as GitHub has it, its tab, and the commit.
    func openDiffed(in repo: FakeRepository) async throws -> (PullRequestSummary, PullRequestTab, String) {
        let listed = toReview[0]
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = try repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try repo.switchTo("feature", creatingFrom: "main")
        let first = try repo.commit([
            "app.go": "package app\n\nfunc Hello() string { return \"hi\" }\n",
            "vendor/example.com/lib/lib.go": "package lib // bumped\n",
            "yarn.lock": "# lockfile\n",
        ], message: "Say hi")
        try repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = first; $0.baseRefOid = branchPoint }
        await tabs.lists.refresh()
        let pullRequest = try #require(tabs.lists.pullRequest(id: listed.id))

        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return (pullRequest, tab, first)
    }

    /// Pushes a commit to the PR, on GitHub and in `repo`'s origin, and returns it.
    func pushCommit(_ files: [String: String], to pullRequest: PullRequestSummary, in repo: FakeRepository) async throws -> String {
        let commit = try repo.commit(files, message: "Another commit")
        try repo.push(asPullRequest: pullRequest.number)
        try await github.edit(pullRequest.id) { $0.headRefOid = commit; $0.commitCount.totalCount += 1 }
        return commit
    }

    /// Fresh models over the same store, as on the next launch.
    func relaunch() throws -> TabsModel {
        Self.tabs(github, store)
    }

    private static func tabs(_ github: FakeGitHub, _ store: PullRequestStore) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        return TabsModel(lists: lists, store: store, notifications: github.notifications(), fallbackInterval: fallbackInterval)
    }

    /// Distinct from GitHub's poll intervals, to tell which one a round waits for.
    static let fallbackInterval = Duration.seconds(45)
}

@MainActor
private final class ShowRecorder {
    var ids: [String] = []
}

private extension PullRequestTab {
    var ready: ReviewDiff? {
        if case let .ready(diff) = phase { diff } else { nil }
    }
}
