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
        #expect(app.shown == [first.id, second.id, first.id], "its tab is shown each time")
        #expect(app.tabs.tab(id: first.id)?.title == "\(first.repository.split(separator: "/").last!) #\(first.number)")
    }

    @Test func aLinkToAStoredPullRequestOpensOrFocusesItsTabWithoutAskingGitHub() async throws {
        let app = try await App()
        let (first, second, linked) = (app.toReview[0], app.toReview[1], app.toReview[2])
        app.tabs.open(first)
        app.tabs.open(second)
        let tab = try #require(app.tabs.tab(id: second.id))
        let requests = await app.github.requestCount

        #expect(await tab.open(try link(to: first, after: "#issuecomment-1")))
        #expect(app.tabs.tabs.map(\.id) == [first.id, second.id], "not opened twice")
        #expect(app.tabs.selected == first.id)

        let differentCase = PullRequestLink(repository: linked.repository.uppercased(), number: linked.number)
        #expect(await tab.open(differentCase))
        #expect(app.tabs.tabs.map(\.id) == [first.id, second.id, linked.id])
        #expect(app.tabs.selected == linked.id)
        #expect(await app.github.requestCount == requests)
    }

    @Test func aLinkToAPullRequestInNeitherListLooksItUpByNumberAndStoresItWithItsTab() async throws {
        let app = try await App()
        let from = app.toReview[0]
        app.tabs.open(from)
        let tab = try #require(app.tabs.tab(id: from.id))
        let url = try #require(URL(string: "https://github.com/tamarinworks/porter/pull/1522/files"))
        let link = try #require(PullRequestLink(url: url))
        #expect(app.tabs.lists.pullRequest(repository: link.repository, number: link.number) == nil, "merged, so in neither list")

        #expect(await tab.open(link))

        #expect(await app.github.numberLookups == ["tamarinworks/porter#1522"])
        let selected = try #require(app.tabs.selected)
        let opened = try #require(app.tabs.tab(id: selected))
        #expect(opened.title == "porter #1522")
        #expect(opened.pullRequest.state == .merged)
        #expect(app.tabs.tabs.map(\.id) == [from.id, opened.id])

        #expect(await tab.open(link))
        #expect(await app.github.numberLookups.count == 1, "known now, so not looked up again")

        // A refresh drops PRs in neither list unless a tab holds them.
        await app.tabs.lists.refresh()
        let nextRun = try app.relaunch()
        #expect(nextRun.tabs.map(\.id) == [from.id, opened.id])
        #expect(nextRun.tabs[1].pullRequest.title == "Read gauge cache status from gazette")
    }

    @Test func aLinkGitHubCantResolveOrAnsweredWithAFailureIsLeftForTheBrowser() async throws {
        let app = try await App()
        let from = app.toReview[0]
        app.tabs.open(from)
        let tab = try #require(app.tabs.tab(id: from.id))

        #expect(await !tab.open(PullRequestLink(repository: "tamarinworks/porter", number: 999_999)))
        #expect(await !tab.open(PullRequestLink(repository: "tamarinworks/nowhere", number: 1)))
        await app.github.fail(with: .status(502))
        #expect(await !tab.open(PullRequestLink(repository: "tamarinworks/porter", number: 1522)))

        #expect(await app.github.numberLookups == ["tamarinworks/porter#999999", "tamarinworks/nowhere#1"])
        #expect(app.tabs.tabs.map(\.id) == [from.id])
        #expect(app.tabs.selected == from.id)
    }

    @Test func closingAPullRequestsTabForgetsItForNextLaunchAndShowsItsNeighbour() async throws {
        let app = try await App()
        let (first, middle, last) = (app.toReview[0], app.toReview[1], app.toReview[2])
        for pullRequest in [first, middle, last] { app.tabs.open(pullRequest) }

        app.tabs.select(middle.id)
        app.tabs.close(middle.id)
        #expect(app.tabs.tabs.map(\.id) == [first.id, last.id])
        #expect(app.tabs.selected == last.id, "the tab that took its place")

        app.tabs.close(last.id)
        #expect(app.tabs.selected == first.id, "the one before, as it was last")

        let nextRun = try app.relaunch()
        #expect(nextRun.tabs.map(\.id) == [first.id])
        #expect(nextRun.selected == first.id)

        app.tabs.close(first.id)
        #expect(app.tabs.selected == nil, "the lists, with no tabs left")
    }

    @Test func closingAnotherTabKeepsTheShownOneAndClosingAllShowsTheLists() async throws {
        let app = try await App()
        let (shown, other) = (app.toReview[0], app.toReview[1])
        app.tabs.open(other)
        app.tabs.open(shown)

        app.tabs.close(other.id)
        #expect(app.tabs.selected == shown.id)

        app.tabs.open(other)
        app.tabs.closeAll()
        #expect(app.tabs.tabs.isEmpty)
        #expect(app.tabs.selected == nil)
        #expect(try app.relaunch().tabs.isEmpty)
    }

    @Test func previousAndNextGoThroughTheListsThenEachTabAndWrapAround() async throws {
        let app = try await App()
        let (first, second) = (app.toReview[0], app.toReview[1])

        app.tabs.selectAdjacent(1)
        #expect(app.tabs.selected == nil, "only the lists to go to")

        app.tabs.open(first)
        app.tabs.open(second)
        app.tabs.select(nil)
        var visited: [String?] = []
        for _ in 0..<3 {
            app.tabs.selectAdjacent(1)
            visited.append(app.tabs.selected)
        }
        #expect(visited == [first.id, second.id, nil])

        visited = []
        for _ in 0..<3 {
            app.tabs.selectAdjacent(-1)
            visited.append(app.tabs.selected)
        }
        #expect(visited == [second.id, first.id, nil])
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
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let branchPoint = try #require(pullRequest.baseRefOid)

        let review = try #require(tab.ready)
        #expect(review.headOid == first)
        #expect(review.mergeBase == branchPoint)
        #expect(review.changes.files.map(\.path) == ["app.go"])
        #expect(review.changes.hidden.map(\.path).sorted() == ["vendor/example.com/lib/lib.go", "yarn.lock"])
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
        #expect(tab.ready?.changes.files.map(\.path) == ["README", "app.go"])
        #expect(tab.selectedFile == "app.go", "the shown file stays shown")
    }

    @Test func pickingACommitShowsOnlyItsChangesUntilTheDiffIsReloaded() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        await app.tabs.lists.refresh()
        await tab.reload()
        #expect(tab.ready?.commits.map(\.oid) == [first, second])
        #expect(tab.selectedFile == "app.go")

        await tab.showCommit(second)
        #expect(tab.shownCommit == second)
        #expect(tab.shown?.files.map(\.path) == ["README"])
        #expect(tab.shown?.hidden.isEmpty == true)
        #expect(tab.selectedFile == "README", "app.go isn't in this commit")

        await tab.showCommit(first)
        #expect(tab.shown?.files.map(\.path) == ["app.go"])
        #expect(tab.shown?.hidden.map(\.path).sorted() == ["vendor/example.com/lib/lib.go", "yarn.lock"])
        #expect(tab.selectedFile == "app.go")

        tab.selectedFile = "yarn.lock"
        await tab.showCommit(nil)
        #expect(tab.shown?.files.map(\.path) == ["README", "app.go"])
        #expect(tab.selectedFile == "yarn.lock", "still in the whole PR's changes")
        #expect(tab.ready?.changes.files.count == 2, "the whole PR's diff is kept")

        // A commit picked before is shown again without git.
        let moved = repo.root.appending(path: "moved")
        try FileManager.default.moveItem(at: repo.checkout, to: moved)
        await tab.showCommit(second)
        #expect(tab.shown?.files.map(\.path) == ["README"])
        try FileManager.default.moveItem(at: moved, to: repo.checkout)

        await tab.reload()
        #expect(tab.shownCommit == nil)
        #expect(tab.shown?.files.map(\.path) == ["README", "app.go"])
    }

    @Test func eachChoiceOfChangesSaysHowMuchItChangesTheFilesToReview() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let second = try await app.pushCommit(["README": "An app\nthat says hi.\n"], to: pullRequest, in: repo)
        await app.tabs.lists.refresh()
        await tab.reload()

        // The vendored file and the lockfile aren't counted, as they aren't reviewed.
        #expect(tab.diffStat(ofCommit: nil) == DiffStat(files: 2, additions: 3, deletions: 2))
        #expect(tab.diffStat(ofCommit: first) == nil, "commits are counted when asked")

        await tab.countCommitChanges()
        #expect(tab.diffStat(ofCommit: first) == DiffStat(files: 1, additions: 1, deletions: 1))
        #expect(tab.diffStat(ofCommit: second) == DiffStat(files: 1, additions: 2, deletions: 1))

        // Counted once: asking again needs no git.
        let moved = repo.root.appending(path: "moved")
        try FileManager.default.moveItem(at: repo.checkout, to: moved)
        await tab.countCommitChanges()
        #expect(tab.diffStat(ofCommit: second) == DiffStat(files: 1, additions: 2, deletions: 1))
        try FileManager.default.moveItem(at: moved, to: repo.checkout)

        let third = try await app.pushCommit(["app.go": "package app\n"], to: pullRequest, in: repo)
        await app.tabs.lists.refresh()
        await tab.reload()
        #expect(tab.diffStat(ofCommit: third) == nil, "reloading starts the counts afresh")
        await tab.countCommitChanges()
        #expect(tab.diffStat(ofCommit: third) == DiffStat(files: 1, additions: 0, deletions: 2))
        #expect(tab.diffStat(ofCommit: first) == DiffStat(files: 1, additions: 1, deletions: 1))
    }

    @Test func hiddenFilesAreListedAndDiffedOnlyWhenAskedFor() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (_, tab, _) = try await app.openDiffed(in: repo)

        #expect(tab.shown?.hidden == [
            ChangedFile(path: "vendor/example.com/lib/lib.go", change: .modified, additions: 1, deletions: 1),
            ChangedFile(path: "yarn.lock", change: .added, additions: 1),
        ])
        #expect(tab.hiddenFileDiff(of: "yarn.lock") == nil)

        tab.selectedFile = "yarn.lock"
        await tab.diffHiddenFile("yarn.lock")

        guard case let .ready(diff)? = tab.hiddenFileDiff(of: "yarn.lock") else {
            Issue.record("expected yarn.lock's diff, got \(String(describing: tab.hiddenFileDiff(of: "yarn.lock")))")
            return
        }
        #expect(diff.change == .added)
        #expect(diff.hunks.flatMap(\.lines).map(\.text) == ["# lockfile"])
        #expect(tab.hiddenFileDiff(of: "vendor/example.com/lib/lib.go") == nil, "only the file asked for")
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
        let repo = try await FakeRepository()
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
        let repo = try await FakeRepository()
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
        let repo = try await FakeRepository()
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
        let repo = try await FakeRepository()
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
    /// The PRs whose tabs the app was asked to show, in order.
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
        let branchPoint = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try await repo.switchTo("feature", creatingFrom: "main")
        let first = try await repo.commit([
            "app.go": "package app\n\nfunc Hello() string { return \"hi\" }\n",
            "vendor/example.com/lib/lib.go": "package lib // bumped\n",
            "yarn.lock": "# lockfile\n",
        ], message: "Say hi")
        try await repo.push(asPullRequest: listed.number)
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
        let commit = try await repo.commit(files, message: "Another commit")
        try await repo.push(asPullRequest: pullRequest.number)
        try await github.edit(pullRequest.id) { $0.headRefOid = commit; $0.commitCount.totalCount += 1 }
        return commit
    }

    /// Fresh models over the same store, as on the next launch.
    func relaunch() throws -> TabsModel {
        Self.tabs(github, store)
    }

    private static func tabs(_ github: FakeGitHub, _ store: PullRequestStore) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        return TabsModel(lists: lists, store: store, client: FakePullRequestDetails().client(), notifications: github.notifications(), fallbackInterval: fallbackInterval)
    }

    /// Distinct from GitHub's poll intervals, to tell which one a round waits for.
    static let fallbackInterval = Duration.seconds(45)
}

@MainActor
private final class ShowRecorder {
    var ids: [String] = []
}

private extension PullRequestTab {
    /// The changes shown, once diffed.
    var shown: ReviewChanges? {
        if case let .ready(changes)? = shownChanges { changes } else { nil }
    }
}

/// A link to the PR on github.com, as its description or a comment would link to it, with
/// `suffix` naming a part of it.
private func link(to pullRequest: PullRequestSummary, after suffix: String = "") throws -> PullRequestLink {
    let url = try #require(URL(string: pullRequest.url.absoluteString + suffix))
    return try #require(PullRequestLink(url: url))
}
