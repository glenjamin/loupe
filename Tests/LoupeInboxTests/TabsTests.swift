import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct TabsTests {
    @Test func choosingAPullRequestOpensItsTabOrFocusesTheOneAlreadyOpen() async throws {
        let app = try await App()
        let (first, second) = (app.toReview[0], app.toReview[1])

        app.tabs.lists.open(first)
        app.tabs.lists.open(second)
        #expect(app.tabs.tabs.map(\.id) == [first.id, second.id])
        #expect(app.tabs.selection == .pullRequest(second.id))

        app.tabs.lists.open(first)
        #expect(app.tabs.tabs.map(\.id) == [first.id, second.id])
        #expect(app.tabs.selection == .pullRequest(first.id))
        #expect(app.tabs.selectedTab?.title == "\(first.repository.split(separator: "/").last!) #\(first.number)")
    }

    @Test func closingATabSelectsItsNeighbourAndTheListsCannotBeClosed() async throws {
        let app = try await App()
        let opened = app.toReview.prefix(3)
        for pullRequest in opened { app.tabs.open(pullRequest) }

        app.tabs.select(.pullRequest(opened[1].id))
        app.tabs.closeSelected()
        #expect(app.tabs.tabs.map(\.id) == [opened[0].id, opened[2].id])
        #expect(app.tabs.selection == .pullRequest(opened[2].id))

        app.tabs.closeSelected()
        #expect(app.tabs.selection == .pullRequest(opened[0].id))
        app.tabs.close(opened[0].id)
        #expect(app.tabs.tabs.isEmpty)
        #expect(app.tabs.selection == .lists)

        app.tabs.closeSelected()
        #expect(app.tabs.selection == .lists)
    }

    @Test func numberedAndCyclingSelectionWrapAroundTheListsTab() async throws {
        let app = try await App()
        let opened = Array(app.toReview.prefix(3))
        for pullRequest in opened { app.tabs.open(pullRequest) }

        app.tabs.selectTab(number: 1)
        #expect(app.tabs.selection == .lists)
        app.tabs.selectTab(number: 3)
        #expect(app.tabs.selection == .pullRequest(opened[1].id))
        app.tabs.selectTab(number: 9)
        #expect(app.tabs.selection == .pullRequest(opened[2].id))
        app.tabs.selectTab(number: 6)
        #expect(app.tabs.selection == .pullRequest(opened[2].id))

        app.tabs.selectNext()
        #expect(app.tabs.selection == .lists)
        app.tabs.selectPrevious()
        #expect(app.tabs.selection == .pullRequest(opened[2].id))
        app.tabs.selectPrevious()
        #expect(app.tabs.selection == .pullRequest(opened[1].id))
    }

    @Test func openTabsAndTheSelectionComeBackNextLaunchEvenForPullRequestsNoLongerListed() async throws {
        let app = try await App()
        let (kept, closed, reviewed) = (app.toReview[0], app.toReview[1], app.toReview[2])
        for pullRequest in [kept, closed, reviewed] { app.tabs.open(pullRequest) }
        app.tabs.close(closed.id)
        app.tabs.select(.pullRequest(kept.id))
        // Reviewing a PR takes it out of the to-review list.
        try await app.github.edit(reviewed.id) { $0.requestedReviewers = [] }
        await app.tabs.lists.refresh()
        #expect(app.tabs.lists.pullRequest(id: reviewed.id) == nil)

        let nextRun = try app.relaunch()

        #expect(nextRun.tabs.map(\.id) == [kept.id, reviewed.id])
        #expect(nextRun.selection == .pullRequest(kept.id))
        #expect(nextRun.tabs[1].pullRequest.title == reviewed.title)
        #expect(nextRun.lists.pullRequest(id: closed.id) != nil, "still listed, so still stored")
    }

    @Test func aTabDiffsThePullRequestFromItsCheckoutAndAgainWhenItsHeadMoves() async throws {
        let repo = try FakeRepository()
        let app = try await App()
        let pullRequest = app.toReview[0]
        try await app.store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: pullRequest.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = try repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try repo.switchTo("feature", creatingFrom: "main")
        let first = try repo.commit([
            "app.go": "package app\n\nfunc Hello() string { return \"hi\" }\n",
            "vendor/example.com/lib/lib.go": "package lib // bumped\n",
            "yarn.lock": "# lockfile\n",
        ], message: "Say hi")
        try repo.push(asPullRequest: pullRequest.number)
        try await app.github.edit(pullRequest.id) { $0.headRefOid = first; $0.baseRefOid = branchPoint }
        await app.tabs.lists.refresh()

        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.selectedTab)
        await tab.load()

        let review = try #require(tab.ready)
        #expect(review.headOid == first)
        #expect(review.mergeBase == branchPoint)
        #expect(review.files.map(\.path) == ["app.go"])
        #expect(review.hiddenCount == 2, "vendor/ by git, yarn.lock by the path filter")
        #expect(tab.selectedFile == "app.go")
        let recorded = try #require(try app.store.diffRecord(for: pullRequest.id))
        #expect(recorded.headRefOid == first)

        // Showing the tab again with the same head doesn't redo the work.
        await tab.load()
        #expect(try app.store.diffRecord(for: pullRequest.id) == recorded)

        let second = try repo.commit(["README": "An app that says hi.\n"], message: "Document it")
        try repo.push(asPullRequest: pullRequest.number)
        try await app.github.edit(pullRequest.id) { $0.headRefOid = second }
        await app.tabs.lists.refresh()
        await tab.load()

        #expect(tab.ready?.headOid == second)
        #expect(tab.ready?.files.map(\.path) == ["README", "app.go"])
        #expect(tab.selectedFile == "app.go", "the shown file stays shown")
    }

    @Test func aTabWithoutACheckoutSaysSoAndAGitFailureShowsGitsMessage() async throws {
        let repo = try FakeRepository()
        let app = try await App()
        let pullRequest = app.toReview[0]
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.selectedTab)

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

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        tabs = Self.tabs(github, store)
        await tabs.lists.refresh()
    }

    var toReview: [PullRequestSummary] {
        tabs.lists.pullRequests(in: .toReview)
    }

    /// Fresh models over the same store, as on the next launch.
    func relaunch() throws -> TabsModel {
        Self.tabs(github, store)
    }

    private static func tabs(_ github: FakeGitHub, _ store: PullRequestStore) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        return TabsModel(lists: lists, store: store)
    }
}

private extension PullRequestTab {
    var ready: ReviewDiff? {
        if case let .ready(diff) = phase { diff } else { nil }
    }
}
