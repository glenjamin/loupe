import Foundation
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ReviewersTests {
    @Test func theViewersOwnPullRequestShowsEachReviewerAndWhereTheirReviewStands() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        try await app.conversations.add(pullRequest.id)
        // The probe has pat-barrow asked, and the viewer's own approval, which as the author's
        // isn't a reviewer's.
        try await app.conversations.review("CHANGES_REQUESTED", by: "tam-fairweather", on: pullRequest.id)
        try await app.conversations.review("COMMENTED", by: "kit-vance", on: pullRequest.id)
        try await app.conversations.review("APPROVED", by: "jules-hollis", on: pullRequest.id)
        try await app.conversations.review("APPROVED", by: "eharcourt", on: pullRequest.id)
        // Asked again after approving, as from github.com's re-request button.
        try await app.conversations.request("jules-hollis", on: pullRequest.id)

        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        let expected: [(String, ReviewerStatus.State)] = [
            ("pat-barrow", .requested),
            ("jules-hollis", .requested),
            ("tam-fairweather", .changesRequested),
            ("kit-vance", .commented),
            ("eharcourt", .approved),
        ]
        let reviewers = try #require(tab.reviewers)
        #expect(reviewers.map(\.reviewer.login) == expected.map(\.0))
        #expect(reviewers.map(\.state) == expected.map(\.1))
        #expect(reviewers.map(\.canReRequest) == [false, false, true, true, true])

        // Next launch shows them from the store, before GitHub answers or if it can't.
        await app.conversations.fail()
        let nextRun = try #require(app.relaunch().tab(id: pullRequest.id))
        #expect(nextRun.reviewers == reviewers)
        await nextRun.load()
        #expect(nextRun.reviewers == reviewers)
    }

    @Test func askingSomeoneToReviewShowsThemAsAskedAndTellsGitHub() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        let people = try await candidates(of: tab, matching: "it")
        // Names match too, and the author can't review their own PR.
        #expect(people.map(\.login) == ["kit-vance"])
        #expect(try await candidates(of: tab, matching: "glen").isEmpty)
        let kit = try #require(people.first { $0.login == "kit-vance" })
        await tab.requestReview(from: kit)

        let devs = try #require(try await candidates(of: tab, matching: "dev").first)
        #expect(devs.kind == .team)
        #expect(devs.displayName == "Devs")
        await tab.requestReview(from: devs)

        #expect(await app.conversations.reviewRequestsReceived == [
            .init(pullRequestId: pullRequest.id, userIds: ["MDQ6VXNlcjM2MjE2NA=="], teamIds: [], union: true),
            .init(pullRequestId: pullRequest.id, userIds: [], teamIds: ["MDQ6VGVhbTE5MDMyNQ=="], union: true),
        ])
        let reviewers = try #require(tab.reviewers)
        #expect(reviewers.map(\.reviewer.displayName) == ["pat-barrow", "kit-vance", "Devs"])
        #expect(reviewers.allSatisfy { $0.state == .requested })
        #expect(tab.reviewRequestError == nil)
        #expect(try app.store.conversation(of: pullRequest.id)?.reviewRequests.map(\.login) == ["pat-barrow", "kit-vance", "tamarinworks/devs"])
        #expect(try await candidates(of: tab, matching: "vance").isEmpty, "those already asked aren't offered")

        // The PR's row names them straight away, rather than at the next refresh, and keeps them.
        let asked: [RequestedReviewer] = [.user(login: "kit-vance"), .team(slug: "devs")]
        #expect(app.tabs.lists.pullRequest(id: pullRequest.id)?.requestedReviewers == asked)
        #expect(try app.relaunch().lists.pullRequest(id: pullRequest.id)?.requestedReviewers == asked)
    }

    @Test func askingSomeoneWhoHasReviewedAsksThemAgain() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        try await app.conversations.add(pullRequest.id)
        try await app.conversations.review("CHANGES_REQUESTED", by: "tam-fairweather", on: pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        let tam = try #require(tab.reviewers?.first { $0.reviewer.login == "tam-fairweather" })
        #expect(tam.state == .changesRequested)
        await tab.requestReview(from: tam.reviewer)

        #expect(await app.conversations.reviewRequestsReceived.map(\.userIds) == [["MDQ6VXNlcjE5NDIwOTM="]])
        #expect(tab.reviewers?.first { $0.reviewer.login == "tam-fairweather" }?.state == .requested)
    }

    @Test func aRefusedRequestPutsTheReviewersBackAndSaysWhy() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()
        let before = tab.reviewers

        let stranger = Reviewer(kind: .user, nodeId: "U_unknown", login: "stranger")
        await tab.requestReview(from: stranger)

        #expect(tab.reviewers == before)
        let error = try #require(tab.reviewRequestError)
        #expect(error.contains("stranger"))
        #expect(error.contains("Could not resolve to a node"))
        #expect(try app.store.conversation(of: pullRequest.id)?.reviewRequests.map(\.login) == ["pat-barrow"])
        #expect(try app.store.lastReviewRequests(in: pullRequest.repository)[stranger.id] == nil, "a refusal isn't kept")
        #expect(app.tabs.lists.pullRequest(id: pullRequest.id)?.requestedReviewers == [], "nor named on its row")

        // The next request clears it.
        let kit = try #require(try await candidates(of: tab, matching: "vance").first)
        await tab.requestReview(from: kit)
        #expect(tab.reviewRequestError == nil)
    }

    @Test func teamsTheTokenCantSeeAreLeftOutQuietly() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        try await app.conversations.add(pullRequest.id)
        await app.conversations.hideTeams()
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))

        let candidates = try await candidates(of: tab, matching: "")
        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { $0.kind == .user })

        // The people found are kept all the same.
        let asked = await app.conversations.candidatePagesAskedFor
        try await tab.fetchReviewerCandidates()
        #expect(await app.conversations.candidatePagesAskedFor == asked)
    }

    @Test func everyoneWhoCouldReviewIsFetchedOnceARepoAndFilteredAsTyped() async throws {
        let app = try await ConversationApp()
        // The probe's six people and three teams then take three pages and two.
        await app.conversations.limitCandidatePages(to: 2)
        let sameRepo = try #require(Dictionary(grouping: app.mine, by: \.repository).values.first { $0.count >= 2 })
        let otherRepo = try #require(app.mine.first { $0.repository != sameRepo[0].repository })
        var tabs: [PullRequestTab] = []
        for pullRequest in [sameRepo[0], sameRepo[1], otherRepo] {
            try await app.conversations.add(pullRequest.id)
            app.tabs.open(pullRequest)
            tabs.append(try #require(app.tabs.tab(id: pullRequest.id)))
        }
        #expect(tabs[0].reviewerCandidates(matching: "") == nil, "none until fetched")

        // Opening the popover twice before GitHub answers asks it once.
        let first = tabs[0]
        async let opening: Void = first.fetchReviewerCandidates()
        async let reopening: Void = first.fetchReviewerCandidates()
        _ = try await (opening, reopening)
        #expect(await app.conversations.candidatePagesAskedFor == 5)
        #expect(tabs[0].reviewerCandidates(matching: "")?.map(\.login) == [
            "pat-barrow", "kit-vance", "jules-hollis", "tam-fairweather", "eharcourt",
            "tamarinworks/devs", "tamarinworks/on-call", "tamarinworks/package-update-reviewers",
        ], "everyone but the author, people first")
        #expect(tabs[0].reviewerCandidates(matching: "HOLLIS")?.map(\.login) == ["jules-hollis"], "by name, ignoring case")
        #expect(tabs[0].reviewerCandidates(matching: "on call")?.map(\.login) == ["tamarinworks/on-call"], "by team name")
        #expect(tabs[0].reviewerCandidates(matching: "on-call")?.map(\.login) == ["tamarinworks/on-call"], "by team slug")
        #expect(tabs[0].reviewerCandidates(matching: "nobody")?.isEmpty == true)

        // Another PR in the same repo shares them; one in another repo fetches its own.
        try await tabs[1].fetchReviewerCandidates()
        #expect(await app.conversations.candidatePagesAskedFor == 5)
        #expect(tabs[1].reviewerCandidates(matching: "it")?.map(\.login) == ["kit-vance"])
        #expect(tabs[2].reviewerCandidates(matching: "") == nil)
        try await tabs[2].fetchReviewerCandidates()
        #expect(await app.conversations.candidatePagesAskedFor == 10)
    }

    @Test func aFailedFetchIsTriedAgainOnTheNextOpening() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))

        await app.conversations.fail()
        await #expect(throws: GitHubError.http(status: 502, message: nil)) { try await tab.fetchReviewerCandidates() }
        #expect(tab.reviewerCandidates(matching: "") == nil)

        await app.conversations.recover()
        #expect(try await candidates(of: tab, matching: "vance").map(\.login) == ["kit-vance"])
    }

    @Test func someoneElsesPullRequestShowsNoReviewers() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        #expect(tab.conversation?.reviewRequests.map(\.login) == ["pat-barrow"])
        #expect(tab.reviewers == nil, "the place is kept for the viewer's own review")
    }

    @Test func thoseAskedLatelyInTheRepoAreOfferedFirst() async throws {
        let app = try await ConversationApp()
        let (asking, sameRepo, otherRepo) = try await openTabsInTwoRepos(app)

        let kit = try #require(try await candidates(of: asking, matching: "vance").first)
        await asking.requestReview(from: kit)
        #expect(try await candidates(of: sameRepo, matching: "").prefix(2).map(\.login) == ["kit-vance", "pat-barrow"])

        let eden = try #require(try await candidates(of: asking, matching: "harcourt").first)
        await asking.requestReview(from: eden)
        #expect(try await candidates(of: sameRepo, matching: "").map(\.login) == [
            "eharcourt", "kit-vance", "pat-barrow", "jules-hollis", "tam-fairweather",
            "tamarinworks/devs", "tamarinworks/on-call", "tamarinworks/package-update-reviewers",
        ], "most recent first, then GitHub's order")
        #expect(try await candidates(of: sameRepo, matching: "c").map(\.login) == [
            "eharcourt", "kit-vance", "tamarinworks/on-call", "tamarinworks/package-update-reviewers",
        ], "still filtered as typed")
        #expect(try await candidates(of: otherRepo, matching: "").prefix(3).map(\.login) == ["pat-barrow", "kit-vance", "jules-hollis"], "another repo keeps GitHub's order")
    }

    @Test func gitHubsSuggestedReviewersAreOfferedFirst() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        try await app.conversations.add(pullRequest.id)
        // The probe suggests tam-fairweather, jules-hollis and ada-reviewer, who isn't among the
        // repo's candidates; tam-fairweather is already asked.
        try await app.conversations.suggestReviewers(on: pullRequest.id)
        try await app.conversations.request("tam-fairweather", on: pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        // Opening the popover as the header fetches ahead asks GitHub once.
        async let opening: Void = tab.fetchReviewerCandidates()
        async let prefetching: Void = tab.fetchReviewerCandidates()
        _ = try await (opening, prefetching)
        #expect(await app.conversations.suggestionFetches == 1)

        let offered = try await candidates(of: tab, matching: "")
        #expect(offered.map(\.login) == [
            "jules-hollis", "ada-reviewer", "kit-vance", "eharcourt",
            "tamarinworks/devs", "tamarinworks/on-call", "tamarinworks/package-update-reviewers",
        ], "suggestions in GitHub's order, then the rest, leaving out the asked and the author")
        #expect(offered.filter(tab.isSuggestedReviewer).map(\.login) == ["jules-hollis", "ada-reviewer"])
        #expect(try await candidates(of: tab, matching: "ada").map(\.login) == ["ada-reviewer"], "still filtered as typed")

        let ada = try #require(offered.first { $0.login == "ada-reviewer" })
        await tab.requestReview(from: ada)
        #expect(await app.conversations.reviewRequestsReceived.map(\.userIds) == [["U_kgDOFakeRev1"]])
        #expect(await app.conversations.suggestionFetches == 1, "fetched once a tab")
    }

    @Test func aSuggestedReviewerAskedLatelyIsOfferedOnceAtTheTop() async throws {
        let app = try await ConversationApp()
        let (asking, sameRepo, _) = try await openTabsInTwoRepos(app)
        for login in ["kit-vance", "jules-hollis"] {
            let reviewer = try #require(try await candidates(of: asking, matching: login).first)
            await asking.requestReview(from: reviewer)
        }

        try await app.conversations.suggestReviewers(on: sameRepo.id)
        #expect(try await candidates(of: sameRepo, matching: "").map(\.login) == [
            "tam-fairweather", "jules-hollis", "ada-reviewer", "kit-vance", "pat-barrow", "eharcourt",
            "tamarinworks/devs", "tamarinworks/on-call", "tamarinworks/package-update-reviewers",
        ])
    }

    @Test func suggestionsThatFailToLoadLeaveTheUsualOrder() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        try await app.conversations.add(pullRequest.id)
        try await app.conversations.suggestReviewers(on: pullRequest.id)
        await app.conversations.failSuggestions()
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))

        let offered = try await candidates(of: tab, matching: "")
        #expect(offered.map(\.login) == [
            "pat-barrow", "kit-vance", "jules-hollis", "tam-fairweather", "eharcourt",
            "tamarinworks/devs", "tamarinworks/on-call", "tamarinworks/package-update-reviewers",
        ])
        #expect(!offered.contains(where: tab.isSuggestedReviewer))

        // Asked again on the next opening.
        _ = try await candidates(of: tab, matching: "")
        #expect(await app.conversations.suggestionFetches == 2)
    }

    @Test func thoseAskedOrReviewingOnTheViewersStoredPullRequestsCountFromTheirLastUpdate() async throws {
        let app = try await ConversationApp()
        let (asking, sameRepo, _) = try await openTabsInTwoRepos(app)
        // pat-barrow is asked in the probe.
        try await app.conversations.review("CHANGES_REQUESTED", by: "tam-fairweather", on: sameRepo.id)
        await sameRepo.load()

        #expect(try await candidates(of: asking, matching: "").prefix(3).map(\.login) == ["pat-barrow", "tam-fairweather", "kit-vance"])

        let eden = try #require(try await candidates(of: asking, matching: "harcourt").first)
        await asking.requestReview(from: eden)
        #expect(try await candidates(of: sameRepo, matching: "").first?.login == "eharcourt", "a request made here is newer")
    }

    @Test func whoWasAskedIsKeptForTheNextRun() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "loupe.sqlite")

        let firstRun = try await ConversationApp(store: PullRequestStore(url: url))
        let (asking, _, _) = try await openTabsInTwoRepos(firstRun)
        let jules = try #require(try await candidates(of: asking, matching: "hollis").first)
        await asking.requestReview(from: jules)

        let nextRun = try await ConversationApp(store: PullRequestStore(url: url))
        let (_, sameRepo, _) = try await openTabsInTwoRepos(nextRun)
        #expect(try await candidates(of: sameRepo, matching: "").prefix(2).map(\.login) == ["jules-hollis", "pat-barrow"])
    }
}

/// Tabs on two of the viewer's PRs in one repo and one in another, each with its conversation
/// on GitHub.
@MainActor
private func openTabsInTwoRepos(_ app: ConversationApp) async throws -> (PullRequestTab, PullRequestTab, PullRequestTab) {
    let first = try #require(app.mine.first { pullRequest in app.mine.count { $0.repository == pullRequest.repository } >= 2 })
    let sameRepo = app.mine.filter { $0.repository == first.repository }
    let otherRepo = try #require(app.mine.first { $0.repository != first.repository })
    var tabs: [PullRequestTab] = []
    for pullRequest in [sameRepo[0], sameRepo[1], otherRepo] {
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        tabs.append(try #require(app.tabs.tab(id: pullRequest.id)))
    }
    return (tabs[0], tabs[1], tabs[2])
}

/// Who `tab` offers to ask for a review when `text` is typed, once the popover's fetch is done.
@MainActor
private func candidates(of tab: PullRequestTab, matching text: String) async throws -> [Reviewer] {
    try await tab.fetchReviewerCandidates()
    return try #require(tab.reviewerCandidates(matching: text))
}
