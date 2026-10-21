import Foundation
import LoupeGit
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

/// A snapshot run clicks through the real app against real GitHub and the user's checkouts, so
/// what it can send is kept to reads.
@MainActor
struct SnapshotGuardTests {
    @Test func aSnapshotRunReadsFromGitHubButNeverWritesToIt() async throws {
        let app = try await GuardedApp()
        let pullRequest = app.mine[0]
        try await app.details.conversations.add(pullRequest.id, number: pullRequest.number)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()
        try await tab.fetchReviewerCandidates()
        let kit = try #require(tab.reviewerCandidates(matching: "vance")?.first, "reads still come through")
        let before = tab.reviewers

        await tab.requestReview(from: kit)
        // pat-barrow was asked on github.com; withdrawing that is a REST write.
        let pat = try #require(tab.requestedReviewers(matching: "barrow").first)
        await tab.removeReviewRequest(from: pat)

        #expect(await app.details.conversations.reviewRequestsReceived.isEmpty)
        #expect(await app.details.conversations.reviewRequestRemovalsReceived.isEmpty)
        #expect(app.guarded.blocked == ["requestReviews", "DELETE /repos/\(pullRequest.repository)/pulls/\(pullRequest.number)/requested_reviewers"])
        #expect(tab.reviewers == before, "put back, as for any refusal")
        #expect(tab.reviewRequestError?.contains("Blocked in snapshot run") == true)

        // Rendering markdown is a POST that changes nothing, so it goes through.
        _ = try await app.client.renderMarkdown("**Looks good**", in: pullRequest.repository)
        #expect(await app.details.markdown.requests.count == 1)
        #expect(app.guarded.blocked.count == 2)
    }

    @Test func aSnapshotRunFetchesForDiffsButNeverChangesTheCheckout() async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("feature", creatingFrom: "main")
        let head = try await repo.commit(["app.go": "package app // feature\n"], message: "Add the feature")
        try await repo.push(asPullRequest: 7)
        try await repo.switchTo("main")
        let refused = ReadOnlyGit.refused.count

        let checkout = repo.checkout
        let fetched = try await ReadOnlyGit.$isOnHere.withValue(true) {
            try await PullRequestDiffer().fetch(number: 7, of: "tamarinworks/app", baseRefName: "main", baseRefOid: nil, in: checkout)
        }
        await #expect(throws: GitError.self) {
            try await ReadOnlyGit.$isOnHere.withValue(true) {
                try await CheckoutSwitcher().switchTo(pullRequest: 7, of: "tamarinworks/app", headRefName: "feature", in: checkout)
            }
        }

        #expect(fetched.headOid == head, "Loupe's own refs are still fetched into")
        #expect(try await repo.git(["branch", "--show-current"], in: repo.checkout) == "main")
        #expect(try await repo.git(["for-each-ref", "refs/remotes/origin/feature"], in: repo.checkout) == "", "not even a tracking branch is written")
        #expect(ReadOnlyGit.refused.dropFirst(refused).contains { $0.hasPrefix("git fetch") && $0.contains("refs/remotes/origin/feature") })
    }
}

/// The lists and tabs over fake GitHubs, with the PRs' details reached only through a
/// `ReadOnlyTransport`, as in a snapshot run.
@MainActor
private struct GuardedApp {
    let github: FakeGitHub
    let details = FakePullRequestDetails()
    let guarded: ReadOnlyTransport
    let client: GitHubClient
    let tabs: TabsModel

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        guarded = ReadOnlyTransport(wrapping: details)
        client = GitHubClient(token: { FakeGitHub.validToken }, transport: guarded)
        let store = try PullRequestStore.inMemory()
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        tabs = .manuallyTimed(lists: lists, store: store, client: client, notifications: github.notifications())
        await lists.refresh()
    }

    var mine: [PullRequestSummary] { tabs.lists.pullRequests(in: .mine) }
}
