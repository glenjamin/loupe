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
        #expect(await github.requestCount == 4)
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
        let lastRefreshed = try #require(secondRun.lastRefreshed)
        #expect(abs(lastRefreshed.timeIntervalSinceNow) < 60)
        #expect(await github.requestCount == 0)
    }

    @Test func aRefreshDropsPullRequestsThatLeftASearchAndUpdatesChangedOnes() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let reviewed = try #require(model.pullRequests(in: .toReview).first)
        let retitled = try #require(model.pullRequests(in: .mine).last)

        await github.edit(.toReview) { $0.removeAll { $0.id == reviewed.id } }
        try await github.edit(.mine) { pullRequests in
            let index = try #require(pullRequests.firstIndex { $0.id == retitled.id })
            pullRequests[index].title = "Retitled"
            pullRequests[index].updatedAt = "2026-10-14T09:00:00Z"
        }
        await model.refresh()

        #expect(model.error == nil)
        #expect(model.pullRequests(in: .toReview).count == 12)
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == reviewed.id })
        let updated = try #require(model.pullRequests(in: .mine).first)
        #expect(updated.id == retitled.id)
        #expect(updated.title == "Retitled")
        #expect(model.pullRequests(in: .mine).count == 50)
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
        #expect(await github.requestCount == 2 * requestsForOneRefresh)
    }

    @Test func refreshesPeriodicallyUntilCancelled() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github, refreshInterval: .milliseconds(10))

        let refreshing = Task { await model.keepRefreshed() }
        defer { refreshing.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while await github.requestCount < 6, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await github.requestCount >= 6)
        #expect(model.hasStoredLists)
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
    staleAfter: Duration = .seconds(300)
) throws -> PullRequestListModel {
    try PullRequestListModel(
        client: github.client(token: token),
        store: store ?? .inMemory(),
        refreshInterval: refreshInterval,
        staleAfter: staleAfter,
        checkoutSearchRoots: [],
        onOpen: { _ in }
    )
}
