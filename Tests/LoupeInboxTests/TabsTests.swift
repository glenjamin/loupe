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

        await tab.open(try link(to: first, after: "#issuecomment-1"))
        #expect(app.tabs.tabs.map(\.id) == [first.id, second.id], "not opened twice")
        #expect(app.tabs.selected == first.id)

        let differentCase = PullRequestLink(repository: linked.repository.uppercased(), number: linked.number)
        await tab.open(differentCase)
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

        await tab.open(link)

        #expect(await app.github.numberLookups == ["tamarinworks/porter#1522"])
        let selected = try #require(app.tabs.selected)
        let opened = try #require(app.tabs.tab(id: selected))
        #expect(opened.title == "porter #1522")
        #expect(opened.pullRequest.state == .merged)
        #expect(app.tabs.tabs.map(\.id) == [from.id, opened.id])

        #expect(!app.tabs.lists.pullRequests(in: .mine, includingClosed: true).contains { $0.id == opened.id }, "the viewer's, but merged")

        await tab.open(link)
        #expect(await app.github.numberLookups.count == 1, "known now, so not looked up again")

        // A refresh drops PRs in neither list unless a tab holds them.
        await app.tabs.lists.refresh()
        let nextRun = try app.relaunch()
        #expect(nextRun.tabs.map(\.id) == [from.id, opened.id])
        #expect(nextRun.tabs[1].pullRequest.title == "Read gauge cache status from gazette")
    }

    @Test func aLinkToTheViewersNewPullRequestPutsItInMineAtOnce() async throws {
        let app = try await App()
        let created = try await app.github.openPullRequest(number: 2001, by: FakeGitHub.viewer)
        let searches = await app.github.searches

        await app.tabs.open(PullRequestLink(repository: created.repository.nameWithOwner, number: created.number))?.value

        #expect(app.tabs.lists.pullRequests(in: .mine).contains { $0.id == created.id })
        #expect(!app.tabs.lists.pullRequests(in: .toReview).contains { $0.id == created.id })
        #expect(await app.github.searches == searches, "without waiting for the lists' refresh")
    }

    @Test func aLinkToANewPullRequestAskingForTheViewersReviewPutsItInToReviewWithTheRequestsDate() async throws {
        let app = try await App()
        let created = try await app.github.openPullRequest(number: 2002, by: "kit-vance", asking: [.user(FakeGitHub.viewer)])
        let requested = try #require(created.requestEvents.last).createdAt

        await app.tabs.open(PullRequestLink(repository: created.repository.nameWithOwner, number: created.number))?.value

        let listed = try #require(app.toReview.first { $0.id == created.id })
        #expect(listed.reviewRequestedAt == wholeSeconds(requested))
        #expect(!app.tabs.lists.pullRequests(in: .mine).contains { $0.id == created.id })
    }

    @Test func aLinkToANewPullRequestAskingATeamsReviewPutsItInToReviewAndARefreshKeepsIt() async throws {
        let app = try await App()
        let created = try await app.github.openPullRequest(number: 2005, by: "kit-vance", asking: [.team("backend")])

        await app.tabs.open(PullRequestLink(repository: created.repository.nameWithOwner, number: created.number))?.value
        #expect(app.toReview.contains { $0.id == created.id }, "any team might be the viewer's")

        await app.tabs.lists.refresh()

        #expect(await !app.github.pullRequests(in: .toReview).contains { $0.id == created.id }, "not a team the viewer is in, so search never finds it")
        #expect(app.tabs.lists.error == nil)
        #expect(app.toReview.contains { $0.id == created.id })
    }

    @Test func aLinkToANewPullRequestAskingNeitherForTheViewerNorByThemLeavesItUnlisted() async throws {
        let app = try await App()
        let created = try await app.github.openPullRequest(number: 2003, by: "kit-vance", asking: [.user("pat-barrow")])

        await app.tabs.open(PullRequestLink(repository: created.repository.nameWithOwner, number: created.number))?.value

        #expect(app.tabs.tab(id: created.id) != nil)
        for list in PullRequestList.allCases {
            #expect(!app.tabs.lists.pullRequests(in: list, includingClosed: true).contains { $0.id == created.id })
        }
    }

    @Test func aNotificationThatAnOpenPullRequestNowAsksForTheViewersReviewPutsItInToReview() async throws {
        let app = try await App()
        let created = try await app.github.openPullRequest(number: 2004, by: "kit-vance")
        await app.tabs.open(PullRequestLink(repository: created.repository.nameWithOwner, number: created.number))?.value
        #expect(!app.toReview.contains { $0.id == created.id })

        try await app.github.requestReview(of: created.id)
        _ = await app.tabs.watchForChanges()

        #expect(await app.github.pullRequestLookups.last == [created.id])
        let listed = try #require(app.toReview.first { $0.id == created.id })
        #expect(listed.reviewRequestedAt != nil)

        await app.tabs.lists.refresh()
        #expect(app.toReview.contains { $0.id == created.id }, "the search agrees")
    }

    @Test func aLinkToAnUnstoredPullRequestShowsItsTabAtOnceWhichBecomesThePullRequestsInPlace() async throws {
        let app = try await App()
        let (first, second) = (app.toReview[0], app.toReview[1])
        app.tabs.open(first)
        let link = PullRequestLink(repository: "tamarinworks/porter", number: 1522)
        await app.github.hold(.numberLookup)

        let lookup = try #require(app.tabs.open(link))
        await app.github.arrival(of: .numberLookup)

        let pending = try #require(app.tabs.items.last?.pending, "a tab from the link alone, before GitHub answers")
        #expect(pending.title == "porter #1522")
        #expect(pending.error == nil, "still being looked up")
        #expect(pending.url.absoluteString == "https://github.com/tamarinworks/porter/pull/1522")
        #expect(app.tabs.selected == pending.id)
        #expect(app.shown.last == pending.id, "brought forward at once")
        #expect(try app.relaunch().tabs.map(\.id) == [first.id], "nothing to store until the PR is found")

        app.tabs.open(PullRequestLink(repository: "TamarinWorks/Porter", number: 1522))
        #expect(app.tabs.items.count == 2, "a second link to it finds its tab")

        app.tabs.open(second)
        app.tabs.select(pending.id)
        await app.github.release(.numberLookup)
        await lookup.value

        #expect(await app.github.numberLookups == ["tamarinworks/porter#1522"], "looked up once")
        let opened = try #require(app.tabs.tabs.first { $0.title == "porter #1522" })
        #expect(app.tabs.items.map(\.id) == [first.id, opened.id, second.id], "in the link's place")
        #expect(app.tabs.selected == opened.id)
        #expect(app.shown.last == opened.id)
        let nextRun = try app.relaunch()
        #expect(nextRun.tabs.map(\.id) == [first.id, opened.id, second.id])
        #expect(nextRun.selected == opened.id)
    }

    @Test func aLinkWhoseTabClosesBeforeThePullRequestIsFoundOpensNothing() async throws {
        let app = try await App()
        let from = app.toReview[0]
        app.tabs.open(from)
        await app.github.hold(.numberLookup)

        let lookup = try #require(app.tabs.open(PullRequestLink(repository: "tamarinworks/porter", number: 1522)))
        let pending = try #require(app.tabs.items.last?.pending)
        app.tabs.close(pending.id)
        #expect(app.tabs.selected == from.id)
        await app.github.release(.numberLookup)
        await lookup.value

        #expect(app.tabs.items.map(\.id) == [from.id])
        #expect(try app.relaunch().tabs.map(\.id) == [from.id])
    }

    @Test func aLinkGitHubCantResolveOrAnsweredWithAFailureKeepsItsTabSayingWhyUntilRetried() async throws {
        let app = try await App()
        let from = app.toReview[0]
        app.tabs.open(from)
        let tab = try #require(app.tabs.tab(id: from.id))

        await tab.open(PullRequestLink(repository: "tamarinworks/porter", number: 999_999))
        await tab.open(PullRequestLink(repository: "tamarinworks/nowhere", number: 1))
        await app.github.fail(with: .status(502))
        await tab.open(PullRequestLink(repository: "tamarinworks/porter", number: 1522))

        #expect(await app.github.numberLookups == ["tamarinworks/porter#999999", "tamarinworks/nowhere#1"])
        let failed = app.tabs.items.compactMap(\.pending)
        #expect(failed.map(\.title) == ["porter #999999", "nowhere #1", "porter #1522"])
        #expect(failed.allSatisfy { $0.error != nil })
        #expect(app.tabs.selected == failed.last?.id, "still shown, saying why")
        #expect(app.tabs.tabs.map(\.id) == [from.id])

        await app.github.recover()
        let retried = try #require(failed.last)
        await app.tabs.retry(retried).value

        let opened = try #require(app.tabs.tabs.last)
        #expect(opened.title == "porter #1522")
        #expect(app.tabs.items.map(\.id) == [from.id, failed[0].id, failed[1].id, opened.id])
        #expect(app.tabs.selected == opened.id)
    }

    @Test func linksFromOtherAppsWaitForTheTabsThenOpenPullRequestsAndPassOtherPagesToTheBrowser() async throws {
        let app = try await App()
        let (first, second) = (app.toReview[0], app.toReview[1])
        let outside = OutsideWorld()
        let links = IncomingLinks(bringForward: { outside.broughtForward += 1 }, openInBrowser: { outside.browsed.append($0.absoluteString) })
        let routed = try #require(URL(string: first.url.absoluteString.replacingOccurrences(of: "https:", with: "loupe:") + "/files"))
        let path = second.url.path(percentEncoded: false)
        let bare = try #require(URL(string: "loupe://\(path)"))

        await links.open([routed, bare])
        #expect(app.tabs.tabs.isEmpty, "nothing opens before launch has finished")
        #expect(outside.broughtForward == 0)

        await links.ready(app.tabs)
        #expect(app.tabs.tabs.map(\.id) == [first.id, second.id], "in the order they arrived")
        #expect(app.tabs.selected == second.id)
        #expect(outside.broughtForward == 2)

        let urls = try [
            "https://github.com/tamarinworks/porter/pull/1522",
            "https://github.com/tamarinworks/porter/issues/1522",
            "loupe:///tamarinworks/porter/pull/999999#issuecomment-1",
            "loupe://example.com/nothing",
        ].map { try #require(URL(string: $0)) }
        await app.github.hold(.numberLookup)
        let opening = Task { await links.open(urls) }
        await app.github.arrival(of: .numberLookup)
        let pending = app.tabs.items.compactMap(\.pending)
        #expect(pending.map(\.title) == ["porter #1522", "porter #999999"], "each shown before GitHub answers either")
        #expect(app.tabs.selected == pending.last?.id)
        #expect(outside.broughtForward == 4, "only for the PRs")

        await app.github.release(.numberLookup)
        await opening.value
        #expect(outside.browsed == ["https://github.com/tamarinworks/porter/issues/1522"], "a loupe link that names no PR is dropped")
        let found = try #require(app.tabs.tabs.last)
        #expect(found.title == "porter #1522")
        #expect(app.tabs.items.map(\.id) == [first.id, second.id, found.id, pending[1].id])
        #expect(pending[1].error != nil, "GitHub has no such PR, which its tab says")
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

        await tab.show(.commit(second))
        #expect(tab.shownChoice == .commit(second))
        #expect(tab.shown?.files.map(\.path) == ["README"])
        #expect(tab.shown?.hidden.isEmpty == true)
        #expect(tab.selectedFile == "README", "app.go isn't in this commit")

        await tab.show(.commit(first))
        #expect(tab.shown?.files.map(\.path) == ["app.go"])
        #expect(tab.shown?.hidden.map(\.path).sorted() == ["vendor/example.com/lib/lib.go", "yarn.lock"])
        #expect(tab.selectedFile == "app.go")

        tab.selectedFile = "yarn.lock"
        await tab.show(.all)
        #expect(tab.shown?.files.map(\.path) == ["README", "app.go"])
        #expect(tab.selectedFile == "yarn.lock", "still in the whole PR's changes")
        #expect(tab.ready?.changes.files.count == 2, "the whole PR's diff is kept")

        // A commit picked before is shown again without git.
        let moved = repo.root.appending(path: "moved")
        try FileManager.default.moveItem(at: repo.checkout, to: moved)
        await tab.show(.commit(second))
        #expect(tab.shown?.files.map(\.path) == ["README"])
        try FileManager.default.moveItem(at: moved, to: repo.checkout)

        await tab.reload()
        #expect(tab.shownChoice == .all)
        #expect(tab.shown?.files.map(\.path) == ["README", "app.go"])
    }

    @Test func aReloadKeepsTheDiffShownUntilTheNewOneReplacesIt() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        await app.tabs.lists.refresh()
        let gate = StepGate(holding: .diffing)
        tab.beforeStep = { await gate.pass($0) }

        let reloading = Task { await tab.reload() }
        await gate.reached()

        #expect(tab.reloading == .diffing)
        #expect(tab.isReplacingShownChanges)
        #expect(tab.ready?.headOid == first, "the old diff stays while the new one is made")
        #expect(tab.shown?.files.map(\.path) == ["app.go"])
        #expect(tab.selectedFile == "app.go")
        #expect(tab.pendingChange == nil, "the new commits aren't offered while they're being taken")

        gate.release()
        await reloading.value

        #expect(tab.reloading == nil)
        #expect(!tab.isReplacingShownChanges)
        #expect(tab.ready?.headOid == second)
        #expect(tab.shown?.files.map(\.path) == ["README", "app.go"])
    }

    @Test func aFirstLoadGoesThroughEachStepBeforeTheDiffIsReady() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, opened, _) = try await app.openDiffed(in: repo)
        app.tabs.close(opened.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        var steps: [DiffStep] = []
        tab.beforeStep = { step in
            steps.append(step)
            guard case let .producing(shown) = tab.phase else {
                Issue.record("expected the step to show, got \(tab.phase)")
                return
            }
            #expect(shown == step)
            #expect(tab.reloading == nil, "there's no diff yet to keep")
        }

        await tab.load()

        #expect(steps == [.resolvingCheckout, .fetching, .diffing])
        #expect(tab.ready?.changes.files.map(\.path) == ["app.go"])
    }

    @Test func pickingACommitKeepsTheChangesShownUntilItsOwnAreDiffed() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        await app.tabs.lists.refresh()
        await tab.reload()
        var gate = StepGate(holding: .diffing)
        tab.beforeStep = { await gate.pass($0) }

        let picking = Task { await tab.show(.commit(second)) }
        await gate.reached()

        #expect(tab.pendingChoice == .commit(second))
        #expect(tab.isReplacingShownChanges)
        #expect(tab.shownChoice == .all, "the whole PR's changes are still shown")
        #expect(tab.shown?.files.map(\.path) == ["README", "app.go"])
        #expect(tab.selectedFile == "app.go")

        gate.release()
        await picking.value

        #expect(tab.pendingChoice == nil)
        #expect(!tab.isReplacingShownChanges)
        #expect(tab.shownChoice == .commit(second))
        #expect(tab.shown?.files.map(\.path) == ["README"])
        #expect(tab.selectedFile == "README")

        // A pick overtaken by another before its diff is ready isn't shown when it is.
        gate = StepGate(holding: .diffing)
        let overtaken = Task { await tab.show(.commit(first)) }
        await gate.reached()
        await tab.show(.all)
        #expect(tab.pendingChoice == nil)
        #expect(tab.shownChoice == .all)
        gate.release()
        await overtaken.value
        #expect(tab.shownChoice == .all, "the whole PR's changes were picked last")
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
        #expect(tab.diffStat(of: .all) == DiffStat(files: 2, additions: 3, deletions: 2))
        #expect(tab.diffStat(of: .commit(first)) == nil, "commits are counted when asked")

        await tab.countCommitChanges()
        #expect(tab.diffStat(of: .commit(first)) == DiffStat(files: 1, additions: 1, deletions: 1))
        #expect(tab.diffStat(of: .commit(second)) == DiffStat(files: 1, additions: 2, deletions: 1))

        // Counted once: asking again needs no git.
        let moved = repo.root.appending(path: "moved")
        try FileManager.default.moveItem(at: repo.checkout, to: moved)
        await tab.countCommitChanges()
        #expect(tab.diffStat(of: .commit(second)) == DiffStat(files: 1, additions: 2, deletions: 1))
        try FileManager.default.moveItem(at: moved, to: repo.checkout)

        let third = try await app.pushCommit(["app.go": "package app\n"], to: pullRequest, in: repo)
        await app.tabs.lists.refresh()
        await tab.reload()
        #expect(tab.diffStat(of: .commit(third)) == nil, "reloading starts the counts afresh")
        await tab.countCommitChanges()
        #expect(tab.diffStat(of: .commit(third)) == DiffStat(files: 1, additions: 0, deletions: 2))
        #expect(tab.diffStat(of: .commit(first)) == DiffStat(files: 1, additions: 1, deletions: 1))
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

    @Test func aHiddenFileKeepsItsLastDiffToShowWhileAnotherCommitsIsMade() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        _ = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        await app.tabs.lists.refresh()
        await tab.reload()
        #expect(tab.lastHiddenFileDiff(of: "yarn.lock") == nil, "never diffed")

        tab.selectedFile = "yarn.lock"
        await tab.diffHiddenFile("yarn.lock")
        await tab.show(.commit(first))

        #expect(tab.hiddenFileDiff(of: "yarn.lock") == nil, "not yet diffed in this commit")
        #expect(tab.lastHiddenFileDiff(of: "yarn.lock")?.hunks.flatMap(\.lines).map(\.text) == ["# lockfile"])
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
        let pages = await app.conversations.pagesServed

        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        await app.conversations.comment("<p>Pushed a fix</p>", on: pullRequest.id)
        _ = await app.tabs.watchForChanges()

        #expect(await app.github.pullRequestLookups.last == [pullRequest.id])
        #expect(tab.pullRequest.headRefOid == second)
        #expect(tab.pendingChange == .newCommits)
        #expect(tab.ready?.headOid == first, "the diff being read stays")
        #expect(try app.store.diffRecord(for: pullRequest.id)?.headRefOid == first)
        #expect(tab.selectedFile == "app.go")

        // The rest of the PR follows GitHub while the reload waits.
        try await app.delay.untilWaiting()
        app.delay.elapse()
        try await until { tab.conversation?.items.last?.event == .comment(bodyHTML: "<p>Pushed a fix</p>", isMinimized: false) && tab.isConversationSettled }
        #expect(await app.conversations.pagesServed == pages + 1)
        #expect(tab.pendingChange == .newCommits)
        #expect(tab.ready?.headOid == first)

        await tab.reload()

        #expect(tab.pendingChange == nil)
        #expect(tab.ready?.headOid == second)
        #expect(await app.conversations.pagesServed == pages + 2)
    }

    @Test func whileNewCommitsWaitTheDiffKeepsItsThreadsButTheViewersOwnShowAtOnce() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, _) = try await app.openDiffed(in: repo)
        let threads = try #require(tab.conversation).threads.count
        let asked = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 3, body: "Why hi?", by: "reviewer")
        try await app.github.edit(pullRequest.id) { $0.reviewThreads.totalCount += 1 }
        _ = await app.tabs.watchForChanges()
        try await app.delay.untilWaiting()
        app.delay.elapse()
        try await until { tab.placedThreadIds == [asked] && tab.isConversationSettled }

        // New commits, and a thread on the new head's lines.
        _ = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        let later = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 1, body: "Rename the package?", by: "reviewer")
        try await app.github.edit(pullRequest.id) { $0.reviewThreads.totalCount += 1 }
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == .newCommits)
        try await app.delay.untilWaiting()
        app.delay.elapse()
        try await until { tab.conversation?.threads.count == threads + 2 && tab.isConversationSettled }
        #expect(tab.unresolvedThreadCount(of: "app.go") == 2, "the file list follows GitHub")
        #expect(tab.placedThreadIds == [asked], "the diff's threads stay as they were for its head")

        // The viewer's reply to a thread on the diff shown shows there at once.
        let thread = try #require(tab.thread(asked))
        tab.startReply(to: thread)
        try #require(tab.threadActivity.replies[asked]).text = "Fixed"
        await tab.sendReply(to: thread)
        #expect(tab.placedThreadIds == [asked])
        #expect(tab.placedThreads.first { $0.id == asked }?.comments.map(\.author?.login) == ["reviewer", FakeGitHub.viewer])

        await tab.reload()

        #expect(tab.pendingChange == nil)
        #expect(tab.placedThreadIds == [asked, later])
    }

    @Test func dismissingNewCommitsKeepsTheDiffAndFollowsTheRestOfThePullRequest() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let pages = await app.conversations.pagesServed
        _ = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        await app.conversations.comment("<p>Pushed a fix</p>", on: pullRequest.id)
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == .newCommits)

        tab.dismissPendingChange()
        #expect(tab.pendingChange == nil)
        try await app.delay.untilWaiting()
        app.delay.elapse()
        try await until { tab.conversation?.items.last?.event == .comment(bodyHTML: "<p>Pushed a fix</p>", isMinimized: false) && tab.isConversationSettled }
        #expect(await app.conversations.pagesServed == pages + 1)
        #expect(tab.ready?.headOid == first)

        let third = try await app.pushCommit(["README": "An app that says hello.\n"], to: pullRequest, in: repo)
        _ = await app.tabs.watchForChanges()
        #expect(tab.pullRequest.headRefOid == third)
        #expect(tab.pendingChange == .newCommits, "more commits are offered again")
    }

    @Test func otherActivityIsFetchedInTheBackgroundWithNoBanner() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let pages = await app.conversations.pagesServed
        let threads = try #require(tab.conversation).threads.count

        await app.conversations.comment("<p>Looks good</p>", on: pullRequest.id, by: "reviewer")
        _ = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 3, body: "Why hi?", by: "reviewer")
        try await app.github.edit(pullRequest.id) { $0.comments.totalCount += 1; $0.reviewDecision = "APPROVED" }
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == nil, "nothing to reload")
        try await app.delay.untilWaiting()
        #expect(await app.conversations.pagesServed == pages, "not until changes settle")

        app.delay.elapse()
        try await until { tab.conversation?.threads.count == threads + 1 && tab.isConversationSettled }
        #expect(await app.conversations.pagesServed == pages + 1)
        #expect(await app.conversations.threadFetches == 0, "the threads come with the conversation")
        #expect(tab.conversation?.items.last?.actor?.login == "reviewer")
        #expect(try app.store.conversation(of: pullRequest.id) == tab.conversation)
        #expect(tab.ready?.headOid == first, "the diff isn't produced again")

        // Nothing new, so nothing more is fetched.
        await app.tabs.lists.refresh()
        _ = await app.tabs.watchForChanges()
        #expect(app.delay.sleeps.count == 1)

        // New commits are still told apart after following the rest.
        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        _ = await app.tabs.watchForChanges()
        #expect(tab.pullRequest.headRefOid == second)
        #expect(tab.pendingChange == .newCommits)
    }

    @Test func aBurstOfChangesIsFetchedOnce() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, _) = try await app.openDiffed(in: repo)
        let pages = await app.conversations.pagesServed

        for index in 1...3 {
            await app.conversations.comment("<p>Comment \(index)</p>", on: pullRequest.id, by: "reviewer")
            try await app.github.edit(pullRequest.id) { $0.comments.totalCount += 1 }
            _ = await app.tabs.watchForChanges()
        }
        try await app.delay.untilWaiting()
        app.delay.elapse()
        try await until { tab.conversation?.items.last?.event == .comment(bodyHTML: "<p>Comment 3</p>", isMinimized: false) && tab.isConversationSettled }

        #expect(await app.conversations.pagesServed == pages + 1)
        #expect(app.delay.sleeps == [.seconds(2)])
        #expect(tab.pendingChange == nil)
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

    @Test func aFailedCheckOfAnOpenPullRequestSaysWhyUntilOneGetsThrough() async throws {
        let app = try await App()
        let pullRequest = app.toReview[0]
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await app.github.refuseNotifications(status: 403)
        _ = await app.tabs.watchForChanges()
        #expect(tab.checkError == nil)
        let stored = tab.pullRequest

        await app.github.fail(with: .status(502))
        _ = await app.tabs.watchForChanges()

        #expect(tab.checkError == "GitHub returned HTTP 502")
        #expect(tab.pullRequest == stored, "the stored PR stays shown")

        await app.github.recover()
        _ = await app.tabs.watchForChanges()

        #expect(tab.checkError == nil)
    }

    @Test func showingAPullRequestChecksItAndItsMergeStateOnceTheSelectionSettles() async throws {
        let app = try await App()
        let pullRequest = app.toReview[0]
        let (lookups, statuses) = (await app.github.pullRequestLookups.count, await app.github.statusLookups.count)

        app.tabs.lists.open(pullRequest)
        try await app.showDelay.untilWaiting()
        #expect(await app.github.pullRequestLookups.count == lookups, "not until the selection settles")
        app.showDelay.elapse()
        try await app.untilStatusLookups(reach: statuses + 1)

        #expect(await app.github.pullRequestLookups.dropFirst(lookups) == [[pullRequest.id]])
        #expect(await app.github.statusLookups.dropFirst(statuses) == [[pullRequest.id]])
        #expect(app.showDelay.sleeps == [.milliseconds(300)])

        app.tabs.select(nil)
        #expect(app.showDelay.sleeps.count == 1, "the lists aren't a PR to check")
    }

    @Test func flickingThroughTabsChecksOnlyTheOneLandedOn() async throws {
        let app = try await App()
        let (first, second, third) = (app.toReview[0], app.toReview[1], app.toReview[2])
        let (lookups, statuses) = (await app.github.pullRequestLookups.count, await app.github.statusLookups.count)

        for pullRequest in [first, second, third] { app.tabs.open(pullRequest) }
        try await until { app.showDelay.sleeps.count == 3 }
        app.showDelay.elapse()
        try await app.untilStatusLookups(reach: statuses + 1)

        #expect(await app.github.pullRequestLookups.dropFirst(lookups) == [[third.id]])
        #expect(await app.github.statusLookups.dropFirst(statuses) == [[third.id]])
    }

    @Test func showingAPullRequestAgainSoonAfterItWasCheckedDoesntAskGitHubAgain() async throws {
        let app = try await App()
        let (first, second) = (app.toReview[0], app.toReview[1])
        let (lookups, statuses) = (await app.github.pullRequestLookups.count, await app.github.statusLookups.count)
        app.tabs.open(first)
        try await app.showDelay.untilWaiting()
        app.showDelay.elapse()
        try await app.untilStatusLookups(reach: statuses + 1)

        // Back to it from the lists, then the app comes to the front.
        app.tabs.select(nil)
        app.tabs.select(first.id)
        app.tabs.checkShownForChanges()
        try await until { app.showDelay.sleeps.count == 3 }
        app.showDelay.elapse()

        app.tabs.open(second)
        try await until { app.showDelay.sleeps.count == 4 }
        app.showDelay.elapse()
        try await app.untilStatusLookups(reach: statuses + 2)

        #expect(await app.github.pullRequestLookups.dropFirst(lookups) == [[first.id], [second.id]])
        #expect(await app.github.statusLookups.dropFirst(statuses) == [[first.id], [second.id]])
    }

    @Test func showingAPullRequestBringsItsMergeStateWithoutWaitingForTheLists() async throws {
        let app = try await App()
        let pullRequest = try #require(app.mine.first { $0.repository == "tamarinworks/gazette" && $0.number == 272 })
        try await app.github.edit(pullRequest.id) { $0.reviewDecision = "REVIEW_REQUIRED" }
        try await app.github.setMergeState(of: pullRequest.id, "BLOCKED")
        try await app.github.setChecks(of: pullRequest.id, state: "SUCCESS", [])
        await app.tabs.lists.refresh()
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()
        #expect(tab.mergeReadiness == .blocked(.notApproved))
        app.tabs.select(nil)

        // Approved while the reviewer was elsewhere; GitHub doesn't count the unblocking as an
        // update, so no notification would bring it.
        try await app.github.edit(pullRequest.id) { $0.reviewDecision = "APPROVED" }
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        app.tabs.select(pullRequest.id)
        try await until { app.showDelay.sleeps.count == 2 }
        app.showDelay.elapse()

        try await until { tab.mergeReadiness == .ready }
        #expect(await app.github.statusLookups.last == [pullRequest.id], "only the shown PR, not the lists")
    }

    @Test func aShownPullRequestSaysItsBeingCheckedUntilGitHubAnswers() async throws {
        let app = try await App()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        await app.github.hold(.lookup)
        await app.conversations.hold(.conversation)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        let loading = Task { await tab.load() }
        await app.conversations.arrival(of: .conversation)
        #expect(tab.isCheckingGitHub, "while its conversation is fetched")
        await app.conversations.release(.conversation)
        await loading.value
        let other = try #require(app.tabs.lists.pullRequests(in: .toReview).dropFirst().first)
        try await app.showDelay.untilWaiting()
        #expect(!tab.isCheckingGitHub, "not while the selection settles")

        app.showDelay.elapse()
        await app.github.arrival(of: .lookup)
        #expect(tab.isCheckingGitHub)
        #expect(!app.tabs.lists.isChecking(other.id), "only the PR shown")

        await app.github.release(.lookup)
        try await until { !tab.isCheckingGitHub }
        #expect(await app.github.statusLookups.last == [pullRequest.id], "its merge state is checked before it stops")
    }

    @Test func aReviewStartedOnGitHubShowsWhenItsTabIsShownAgain() async throws {
        let app = try await App()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        let tab = try await app.openLoaded(pullRequest)
        #expect(tab.pendingReview == nil && tab.pendingComments.isEmpty)
        app.tabs.select(nil)

        // Started on github.com while the viewer was elsewhere, which isn't activity on the PR.
        let reviewId = try await app.conversations.startPendingReview(on: pullRequest.id, path: "app.go", line: 11, body: "Why three?")
        try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 14, pending: true, body: "And here?", by: FakeGitHub.viewer)
        await app.conversations.hold(.threads)
        app.tabs.select(pullRequest.id)
        try await until { app.showDelay.sleeps.count == 2 }
        app.showDelay.elapse()
        await app.conversations.arrival(of: .threads)
        #expect(tab.isCheckingGitHub, "while its threads are fetched")

        await app.conversations.release(.threads)
        try await until { !tab.isCheckingGitHub }
        #expect(tab.pendingReview?.id == reviewId)
        #expect(tab.pendingComments.map(\.thread.lines?.upperBound) == [11, 14])
        #expect(tab.placedThreads.filter(\.isPending).count == 2, "on the diff")
        #expect(tab.pullRequest.updatedAt == pullRequest.updatedAt)
    }

    @Test func aReviewDiscardedOnGitHubGoesWhenItsTabIsShownAgain() async throws {
        let app = try await App()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        try await app.conversations.startPendingReview(on: pullRequest.id, path: "app.go", line: 11, body: "Why three?")
        let tab = try await app.openLoaded(pullRequest)
        #expect(tab.pendingReview != nil && tab.pendingComments.count == 1)
        app.tabs.select(nil)

        await app.conversations.discardPendingReview(on: pullRequest.id)
        app.tabs.select(pullRequest.id)
        try await until { app.showDelay.sleeps.count == 2 }
        app.showDelay.elapse()

        try await until { tab.pendingReview == nil }
        #expect(tab.pendingComments.isEmpty)
        #expect(!tab.placedThreads.contains { $0.isPending })
    }

    @Test func showingATabWithNoChangesFetchesOnlyItsThreads() async throws {
        let app = try await App()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        let tab = try await app.openLoaded(pullRequest)
        app.tabs.select(nil)
        let (pages, threadFetches) = (await app.conversations.pagesServed, await app.conversations.threadFetches)

        await app.conversations.hold(.threads)
        app.tabs.select(pullRequest.id)
        try await until { app.showDelay.sleeps.count == 2 }
        app.showDelay.elapse()
        await app.conversations.arrival(of: .threads)
        await app.conversations.release(.threads)

        try await until { !tab.isCheckingGitHub }
        #expect(await app.conversations.threadFetches == threadFetches + 1)
        #expect(await app.conversations.pagesServed == pages, "not the whole conversation")
    }

    @Test func comingBackToATabWithNewCommitsWaitingReloadsItAtOnce() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, _) = try await app.openDiffed(in: repo)
        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == .newCommits)
        app.tabs.select(nil)
        let (lookups, settles) = (await app.github.pullRequestLookups.count, app.showDelay.sleeps.count)

        app.tabs.select(pullRequest.id)

        #expect(tab.pendingChange == nil, "not offered, as none of them is being read yet")
        try await until { tab.ready?.headOid == second }
        #expect(tab.pendingChange == nil)
        #expect(tab.selectedFile == "app.go")
        #expect(app.showDelay.sleeps.count == settles, "without waiting for the selection to settle")
        #expect(await app.github.pullRequestLookups.dropFirst(lookups) == [[pullRequest.id]], "looked up once, by the reload")

        // Likewise for commits offered while the tab was read, once the app comes to the front.
        let third = try await app.pushCommit(["README": "An app that says hello.\n"], to: pullRequest, in: repo)
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == .newCommits)
        app.tabs.checkShownForChanges()
        try await until { tab.ready?.headOid == third }
        #expect(tab.pendingChange == nil)
    }

    @Test func newCommitsFoundByCheckingATabAsItsShownAreReloadedRatherThanOffered() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        app.tabs.select(nil)
        let lookups = await app.github.pullRequestLookups.count

        app.tabs.select(pullRequest.id)
        try await until { app.showDelay.sleeps.count == 2 }
        #expect(tab.ready?.headOid == first, "not known until checked")
        app.showDelay.elapse()

        var offered = false
        try await until {
            offered = offered || tab.pendingChange != nil
            return tab.ready?.headOid == second
        }
        #expect(!offered, "no banner on the way")
        #expect(await app.github.pullRequestLookups.dropFirst(lookups) == [[pullRequest.id]], "the reload doesn't look it up again")
    }

    @Test func newCommitsFoundWhileATabIsReadAreOfferedRatherThanReloaded() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let statuses = await app.github.statusLookups.count
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        try await app.showDelay.untilWaiting()
        app.showDelay.elapse()
        try await app.untilStatusLookups(reach: statuses + 1)
        #expect(tab.pendingChange == nil, "checked as it was shown, with nothing new")

        _ = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        _ = await app.tabs.watchForChanges()

        #expect(tab.pendingChange == .newCommits)
        #expect(tab.ready?.headOid == first, "the diff being read stays")
        #expect(try app.store.diffRecord(for: pullRequest.id)?.headRefOid == first)
    }

    @Test func aCommentBeingWrittenOnALineKeepsNewCommitsOfferedOnComingBack() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, first) = try await app.openDiffed(in: repo)
        let second = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        _ = await app.tabs.watchForChanges()
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 3))
        try #require(tab.threadActivity.newComment?.draft).text = "Why hi?"

        app.tabs.select(nil)
        app.tabs.select(pullRequest.id)
        app.tabs.checkShownForChanges()
        try await until { app.showDelay.sleeps.count == 3 }
        app.showDelay.elapse()

        #expect(tab.pendingChange == .newCommits, "the new head could move the comment's line")
        #expect(tab.ready?.headOid == first)
        #expect(tab.threadActivity.newComment?.draft.text == "Why hi?")

        tab.cancelComment()
        app.tabs.checkShownForChanges()
        try await until { tab.ready?.headOid == second }
        #expect(tab.pendingChange == nil)
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
struct PendingReviewWhileNewCommitsWaitTests {
    @Test func theViewersReviewShowsOnTheDiffBeingReadAtOnce() async throws {
        let repo = try await FakeRepository()
        let app = try await App()
        let (pullRequest, tab, _) = try await app.openDiffed(in: repo)
        _ = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest, in: repo)
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == .newCommits)

        try await reviewComment("Why hi?", line: 3, on: tab)
        let started = try #require(tab.placedThreads.first { $0.isPending })
        #expect(tab.placedThreadIds.contains(started.id), "shown on the diff being read")

        await tab.submitReview(as: .approve)
        #expect(tab.placedThreads.first { $0.id == started.id }?.isPending == false, "submitted at once")

        try await reviewComment("And this?", line: 1, on: tab)
        let abandoned = try #require(tab.placedThreads.first { $0.isPending })
        await tab.discardReview()
        #expect(!tab.placedThreadIds.contains(abandoned.id), "gone with the review")
        #expect(tab.placedThreadIds.contains(started.id))
        #expect(tab.pendingChange == .newCommits, "the reload still waits")
    }

    private func reviewComment(_ text: String, line: Int, on tab: PullRequestTab) async throws {
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: line))
        try #require(tab.threadActivity.newComment?.draft).text = text
        await tab.sendReviewComment()
        #expect(tab.threadActivity.newCommentError == nil)
    }
}

@MainActor
private struct App {
    let github: FakeGitHub
    let details = FakePullRequestDetails()
    let store: PullRequestStore
    let tabs: TabsModel
    /// What tabs wait on before fetching changes, which only end when the test says.
    let delay = ManualDelay()
    /// What the shown PR waits on before it's checked, likewise.
    let showDelay = ManualDelay()
    /// The PRs whose tabs the app was asked to show, in order.
    private let showRecorder = ShowRecorder()

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        tabs = Self.tabs(github, details, store, delay, showDelay)
        tabs.show = { [showRecorder] in showRecorder.ids.append($0) }
        await tabs.lists.refresh()
    }

    var shown: [String] {
        showRecorder.ids
    }

    var conversations: FakeConversations { details.conversations }

    var toReview: [PullRequestSummary] {
        tabs.lists.pullRequests(in: .toReview)
    }

    var mine: [PullRequestSummary] {
        tabs.lists.pullRequests(in: .mine)
    }

    /// Waits for GitHub to have answered `count` status lookups in all, as the shown PR is
    /// checked in the background.
    func untilStatusLookups(reach count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await github.statusLookups.count < count {
            try #require(ContinuousClock.now < deadline, "waited too long")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Opens the first to-review PR, pushed to `repo` with one commit, once its diff is ready.
    /// Returns the PR as GitHub has it, its tab, and the commit.
    /// Opens the PR's tab and waits for it to load, leaving the check made as it's shown waiting
    /// for the selection to settle.
    func openLoaded(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }

    func openDiffed(in repo: FakeRepository) async throws -> (PullRequestSummary, PullRequestTab, String) {
        let listed = toReview[0]
        try await conversations.add(listed.id)
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
        Self.tabs(github, details, store, delay, showDelay)
    }

    private static func tabs(_ github: FakeGitHub, _ details: FakePullRequestDetails, _ store: PullRequestStore, _ delay: ManualDelay, _ showDelay: ManualDelay) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        return .manuallyTimed(lists: lists, store: store, client: details.client(), notifications: github.notifications(), fallbackInterval: fallbackInterval, delay: delay, showDelay: showDelay)
    }

    /// Distinct from GitHub's poll intervals, to tell which one a round waits for.
    static let fallbackInterval = Duration.seconds(45)
}

@MainActor
private final class ShowRecorder {
    var ids: [String] = []
}

/// What incoming links asked of the rest of the system: the window brought forward, and pages
/// opened in the browser.
@MainActor
private final class OutsideWorld {
    var broughtForward = 0
    var browsed: [String] = []
}

/// Holds a tab's git work the first time it reaches one step, until released, so a test can
/// look at the tab meanwhile.
@MainActor
private final class StepGate {
    private let held: DiffStep
    private var hasArrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    init(holding step: DiffStep) {
        held = step
    }

    /// For the tab's `beforeStep`.
    func pass(_ step: DiffStep) async {
        guard step == held, !hasArrived else { return }
        hasArrived = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { waiting = $0 }
    }

    /// Returns once the work is held.
    func reached() async {
        if hasArrived { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}

private extension PullRequestTab {
    /// The changes shown, once diffed.
    var shown: ReviewChanges? {
        if case let .ready(changes)? = shownChanges { changes } else { nil }
    }

    /// The threads the diff of app.go shows, on its lines or after them, by id.
    var placedThreadIds: [String] {
        guard let file = file("app.go"), let threads = threads(on: file) else { return [] }
        return threads.anchored.flatMap(\.threads).map(\.id) + threads.elsewhere.map(\.id)
    }
}

/// `date` as GitHub reports it, to the second.
private func wholeSeconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
}

/// A link to the PR on github.com, as its description or a comment would link to it, with
/// `suffix` naming a part of it.
private func link(to pullRequest: PullRequestSummary, after suffix: String = "") throws -> PullRequestLink {
    let url = try #require(URL(string: pullRequest.url.absoluteString + suffix))
    return try #require(PullRequestLink(url: url))
}
