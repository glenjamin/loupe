import Foundation
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct PullRequestListTests {
    @Test func showsBothColumnsNewestFirst() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json", reversed: true)
        let model = try listModel(github)

        await model.refresh()

        #expect(model.error == nil)
        #expect(model.pullRequests(in: .mine).count == 50)
        #expect(model.pullRequests(in: .toReview).count == 13)
        for list in PullRequestList.allCases {
            let dates = model.pullRequests(in: list).map(\.updatedAt)
            #expect(dates == dates.sorted(by: >))
        }

        let newest = try #require(model.pullRequests(in: .toReview).first)
        #expect(newest.repository == "tamarinworks/atrium")
        #expect(newest.number == 2928)
        #expect(newest.author == "rowan-ashby")
        #expect(newest.reviewDecision == .reviewRequired)
        #expect(newest.checks == .success)
        #expect(newest.url == URL(string: "https://github.com/tamarinworks/atrium/pull/2928"))
        let served = try #require(await github.pullRequests(in: .toReview).first { $0.id == newest.id })
        #expect(newest.headRefOid == served.headRefOid)
        #expect(newest.baseRefOid == served.baseRefOid)
    }

    @Test func keepsDraftsAndRowsWithoutReviewOrChecks() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)

        await model.refresh()

        let mine = model.pullRequests(in: .mine)
        let draft = try #require(mine.first { $0.repository == "tamarinworks/gazette" && $0.number == 273 })
        #expect(draft.isDraft)
        #expect(draft.reviewDecision == nil)

        let unchecked = try #require(mine.first { $0.repository == "tamarinworks/hadley" && $0.number == 1 })
        #expect(unchecked.checks == nil)
        #expect(unchecked.reviewDecision == .approved)
    }

    @Test func pagesThroughEverySearchResult() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json", maxPageSize: 20)
        let model = try listModel(github)

        await model.refresh()

        #expect(model.error == nil)
        let expected = await github.pullRequests(in: .mine).map(\.id)
        #expect(Set(model.pullRequests(in: .mine).map(\.id)) == Set(expected))
        #expect(expected.count == 50)
        #expect(model.pullRequests(in: .toReview).count == 13)
        // Three pages of mine, one of to-review.
        #expect(await github.searches.count == 4)
    }

    @Test func rowsCarryEachOfTheirChecksAfterARefresh() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)

        await model.refresh()

        let mine = model.pullRequests(in: .mine)
        let failing = try #require(mine.first { $0.repository == "tamarinworks/gatehouse" && $0.number == 172 })
        #expect(failing.checks == .failure)
        #expect(failing.checkContexts.tooltip == """
            2 of 5 checks failed
            ✗ codecov/patch — 76.92% of diff hit (target 98.23%)
            ✗ codecov/project — 96.01% (-2.22%) compared to 8b4635f
            ✓ ci/circleci: build — Your tests passed on CircleCI!
            ✓ ci/circleci: lint — Your tests passed on CircleCI!
            ✓ ci/circleci: test — Your tests passed on CircleCI!
            """)
        let unchecked = try #require(mine.first { $0.repository == "tamarinworks/hadley" && $0.number == 1 })
        #expect(unchecked.checkContexts.tooltip == nil)

        // Every open PR's checks are asked for once, in batches GitHub answers well in time.
        let lookups = await github.statusLookups
        #expect(lookups.allSatisfy { $0.count <= 50 })
        let asked = lookups.flatMap(\.self)
        #expect(asked.count == Set(asked).count)
        #expect(Set(asked) == Set((mine + model.pullRequests(in: .toReview)).map(\.id)))
    }

    @Test func rowsSayWhetherTheyConflictWithTheirBaseAfterARefresh() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)

        await model.refresh()

        let mine = model.pullRequests(in: .mine)
        let conflicting = try #require(mine.first { $0.repository == "tamarinworks/bedrock" && $0.number == 2335 })
        #expect(conflicting.mergeable == .conflicting)
        let clean = try #require(mine.first { $0.repository == "tamarinworks/gatehouse" && $0.number == 172 })
        #expect(clean.mergeable == .mergeable)
        // GitHub hadn't worked this one out yet.
        let undecided = try #require(mine.first { $0.repository == "tamarinworks/gazette" && $0.number == 272 })
        #expect(undecided.mergeable == .unknown)

        // Looking a PR up for its other changes doesn't ask again, so keeps what was found.
        try await model.checkForChanges(to: [conflicting.id])
        #expect(model.pullRequest(id: conflicting.id)?.mergeable == .conflicting)
    }

    @Test func checksThatChangeWithoutUpdatingThePullRequestAreFoundOnTheNextRefresh() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let before = try #require(model.pullRequests(in: .toReview).first)
        #expect(before.checks == .success)

        try await github.setChecks(of: before.id, state: "FAILURE", [
            .status("ci/circleci: build", "SUCCESS", description: "Your tests passed on CircleCI!"),
            .status("ci/circleci: test", "PENDING", description: "CircleCI is running your tests"),
            .checkRun("codecov/project", status: "COMPLETED", conclusion: "SKIPPED"),
            .checkRun("codecov/patch", status: "COMPLETED", conclusion: "FAILURE", title: "80.00% of diff hit (target 90.00%)"),
        ])
        await model.refresh()

        let after = try #require(model.pullRequests(in: .toReview).first { $0.id == before.id })
        #expect(after.updatedAt == before.updatedAt)
        #expect(after.checks == .failure)
        #expect(after.checkContexts.tooltip == """
            1 of 4 checks failed
            ✗ codecov/patch — 80.00% of diff hit (target 90.00%)
            ● ci/circleci: test — CircleCI is running your tests
            ✓ ci/circleci: build — Your tests passed on CircleCI!
            – codecov/project
            """)
    }

    @Test func showsTheListsStoredByThePreviousRunBeforeRefreshing() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "loupe.sqlite")

        let firstRun = try listModel(try FakeGitHub(fixture: "pr-list.json"), store: PullRequestStore(url: url))
        await firstRun.refresh()

        let github = try FakeGitHub(fixture: "pr-list.json")
        let secondRun = try listModel(github, store: PullRequestStore(url: url))

        #expect(secondRun.hasStoredLists)
        #expect(secondRun.pullRequests(in: .mine) == firstRun.pullRequests(in: .mine))
        #expect(secondRun.pullRequests(in: .toReview) == firstRun.pullRequests(in: .toReview))
        #expect(secondRun.pullRequests(in: .toReview).first?.checkContexts.isEmpty == false)
        let lastRefreshed = try #require(secondRun.lastRefreshed)
        #expect(abs(lastRefreshed.timeIntervalSinceNow) < 60)
        #expect(await github.requestCount == 0)
    }

    @Test func theFirstLoadAsksForOpenPullRequestsAndLaterOnesForChanges() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)

        await model.refresh()
        let firstLoad = await github.searches
        #expect(firstLoad.count == 2)
        #expect(firstLoad.allSatisfy { $0.contains("is:open") && !$0.contains("updated:") })

        await model.refresh()
        let refresh = await github.searches.dropFirst(firstLoad.count)
        #expect(refresh.count == 2)
        #expect(refresh.allSatisfy { !$0.contains("is:open") && $0.contains("updated:>=") })
    }

    @Test func aMergedPullRequestLeavesTheDefaultViewButStaysStored() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let store = try PullRequestStore.inMemory()
        let model = try listModel(github, store: store)
        await model.refresh()
        let merged = try #require(model.pullRequests(in: .mine).last)

        try await github.merge(merged.id)
        await model.refresh()

        #expect(model.error == nil)
        #expect(model.pullRequests(in: .mine).count == 49)
        #expect(!model.pullRequests(in: .mine).contains { $0.id == merged.id })
        let shown = try #require(model.pullRequests(in: .mine, includingClosed: true).first)
        #expect(shown.id == merged.id)
        #expect(shown.state == .merged)
        #expect(shown.mergedAt != nil)
        #expect(try store.snapshot()[.mine].contains { $0.id == merged.id && $0.state == .merged })
    }

    @Test func aRefreshWithNoChangesKeepsEverything() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let mine = model.pullRequests(in: .mine)
        let toReview = model.pullRequests(in: .toReview)

        await model.refresh()

        #expect(model.error == nil)
        #expect(model.pullRequests(in: .mine) == mine)
        #expect(model.pullRequests(in: .toReview) == toReview)
        #expect(mine.count == 50)
        #expect(toReview.count == 13)
    }

    @Test func aRefreshUpdatesChangedPullRequests() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let retitled = try #require(model.pullRequests(in: .mine).last)

        try await github.edit(retitled.id) { $0.title = "Retitled" }
        await model.refresh()

        let updated = try #require(model.pullRequests(in: .mine).first)
        #expect(updated.id == retitled.id)
        #expect(updated.title == "Retitled")
        #expect(model.pullRequests(in: .mine).count == 50)
    }

    @Test func aReviewedPullRequestLeavesToReviewButATeamRequestKeepsOneThere() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json", viewerTeams: ["backend"])
        let model = try listModel(github)
        await model.refresh()
        let toReview = model.pullRequests(in: .toReview)
        let reviewed = toReview[0]
        let teamRequested = toReview[1]

        try await github.edit(reviewed.id) { $0.requestedReviewers = [.user("someone-else")] }
        try await github.edit(teamRequested.id) { $0.requestedReviewers = [.team("backend")] }
        await model.refresh()

        #expect(model.error == nil)
        #expect(!model.pullRequests(in: .toReview, includingClosed: true).contains { $0.id == reviewed.id })
        #expect(model.pullRequests(in: .toReview).contains { $0.id == teamRequested.id })
        #expect(model.pullRequests(in: .toReview).count == 12)
    }

    @Test func aPullRequestThatCanNoLongerBeFoundLeavesToReview() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let deleted = try #require(model.pullRequests(in: .toReview).first)

        await github.delete(deleted.id)
        await model.refresh()

        #expect(model.error == nil)
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == deleted.id })
        #expect(model.pullRequests(in: .toReview).count == 12)
    }

    @Test func theRefreshTimeAdvancesOnlyWhenARefreshSucceeds() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let store = try PullRequestStore.inMemory()
        let model = try listModel(github, store: store)
        await model.refresh()
        let loaded = try store.snapshot()
        let lastRefreshed = try #require(model.lastRefreshed)

        await github.fail(with: .status(502))
        await model.refresh()
        #expect(model.lastRefreshed == lastRefreshed)

        await github.recover()
        let searchesBefore = await github.searches.count
        await model.refresh()

        #expect(model.error == nil)
        #expect(try #require(model.lastRefreshed) > lastRefreshed)
        // Changes are still asked for from just before the last successful refresh.
        for search in await github.searches.dropFirst(searchesBefore) {
            let list: PullRequestList = search.contains("author:@me") ? .mine : .toReview
            let refreshedAt = try #require(loaded.refreshedAt(list))
            let since = try Date(String(try #require(search.firstMatch(of: /updated:>=(\S+)/)).1), strategy: .iso8601)
            #expect(since <= refreshedAt.addingTimeInterval(-120))
            #expect(since > refreshedAt.addingTimeInterval(-121))
        }
    }

    @Test func aFailedRefreshKeepsTheStoredListsAndReportsTheError() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let mine = model.pullRequests(in: .mine)
        let toReview = model.pullRequests(in: .toReview)
        let lastRefreshed = model.lastRefreshed

        await github.fail(with: .status(502))
        await model.refresh()

        #expect(model.error == "GitHub returned HTTP 502")
        #expect(model.pullRequests(in: .mine) == mine)
        #expect(model.pullRequests(in: .toReview) == toReview)
        #expect(model.lastRefreshed == lastRefreshed)

        await github.recover()
        await model.refresh()

        #expect(model.error == nil)
        #expect(try #require(model.lastRefreshed) > #require(lastRefreshed))
    }

    @Test func aRejectedTokenOnFirstLaunchShowsAnError() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github, token: "expired")

        await model.refresh()

        #expect(!model.hasStoredLists)
        #expect(model.error == "GitHub returned HTTP 401: Bad credentials")
    }

    @Test func aGraphQLErrorShowsAnError() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        await github.fail(with: try .fixture("graphql-error.json"))
        let model = try listModel(github)

        await model.refresh()

        #expect(!model.hasStoredLists)
        #expect(model.error == "GitHub query failed: Field 'nonexistentField' doesn't exist on type 'User'")
    }

    @Test func aMissingGitHubLoginShowsAnError() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let client = github.client { throw GitHubError.token("not logged in to any GitHub hosts") }
        let model = try PullRequestListModel(client: client, store: .inMemory(), checkoutSearchRoots: [], onOpen: { _ in })

        await model.refresh()

        #expect(!model.hasStoredLists)
        #expect(model.error == "Couldn't get a GitHub token from `gh auth token`: not logged in to any GitHub hosts")
        #expect(await github.requestCount == 0)
    }

    @Test func refreshesOnReturnOnlyOnceTheListsAreStale() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let store = try PullRequestStore.inMemory()
        try await listModel(github, store: store).refresh()
        let requestsForOneRefresh = await github.requestCount

        try await listModel(github, store: store, staleAfter: .seconds(300)).refreshIfStale()
        #expect(await github.requestCount == requestsForOneRefresh)

        try await listModel(github, store: store, staleAfter: .zero).refreshIfStale()
        #expect(await github.requestCount > requestsForOneRefresh)
    }

    @Test func refreshesEachIntervalUntilCancelled() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let clock = ManualClock()
        let model = try listModel(github, refreshInterval: .seconds(180), sleep: { try await clock.sleep(for: $0) })

        let refreshing = Task { await model.keepRefreshed() }
        defer { refreshing.cancel() }
        try await clock.untilAsleep()
        #expect(model.hasStoredLists)
        var requests = await github.requestCount
        for _ in 1...3 {
            try await clock.advance()
            let after = await github.requestCount
            #expect(after > requests, "each interval refreshes again")
            requests = after
        }
        #expect(clock.sleeps == Array(repeating: .seconds(180), count: 4))

        refreshing.cancel()
        await refreshing.value
        #expect(await github.requestCount == requests, "nothing refreshes once cancelled")
    }

    @Test func openingAPullRequestHandsItToTheSelectionHandler() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        var opened: [URL] = []
        let model = try PullRequestListModel(client: github.client(), store: .inMemory(), checkoutSearchRoots: [], onOpen: { opened.append($0.url) })
        await model.refresh()

        let pullRequest = try #require(model.pullRequests(in: .toReview).first)
        model.open(pullRequest)

        #expect(opened == [pullRequest.url])
    }
}

@MainActor
private func listModel(
    _ github: FakeGitHub,
    token: String = FakeGitHub.validToken,
    store: PullRequestStore? = nil,
    refreshInterval: Duration = .seconds(180),
    staleAfter: Duration = .seconds(300),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
) throws -> PullRequestListModel {
    try PullRequestListModel(
        client: github.client(token: token),
        store: store ?? .inMemory(),
        refreshInterval: refreshInterval,
        staleAfter: staleAfter,
        sleep: sleep,
        checkoutSearchRoots: [],
        onOpen: { _ in }
    )
}

/// Stands in for the clock the refresh loop sleeps on: a sleep lasts until the test advances
/// time past it, or the sleeping task is cancelled.
@MainActor
private final class ManualClock {
    /// How long each sleep asked for, in order.
    private(set) var sleeps: [Duration] = []
    private var sleeper: CheckedContinuation<Void, Error>?

    func sleep(for duration: Duration) async throws {
        sleeps.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { sleeper = $0 }
        } onCancel: {
            Task { @MainActor in self.wake(throwing: CancellationError()) }
        }
    }

    /// Ends the current sleep, as if its time had passed, and waits for the next one.
    func advance() async throws {
        wake(throwing: nil)
        try await untilAsleep()
    }

    /// Waits for the loop to sleep. The deadline only guards against a hang.
    func untilAsleep() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while sleeper == nil {
            try #require(ContinuousClock.now < deadline, "the refresh loop never went to sleep")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func wake(throwing error: (any Error)?) {
        guard let sleeper else { return }
        self.sleeper = nil
        if let error { sleeper.resume(throwing: error) } else { sleeper.resume() }
    }
}
