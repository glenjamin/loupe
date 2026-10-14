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

        let people = try await tab.reviewerCandidates(matching: "it")
        // GitHub matches names too, and the author can't review their own PR.
        #expect(people.map(\.login) == ["kit-vance"])
        let kit = try #require(people.first { $0.login == "kit-vance" })
        await tab.requestReview(from: kit)

        let devs = try #require(try await tab.reviewerCandidates(matching: "dev").first)
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
        #expect(try await tab.reviewerCandidates(matching: "vance").isEmpty, "those already asked aren't offered")
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

        // The next request clears it.
        let kit = try #require(try await tab.reviewerCandidates(matching: "vance").first)
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

        let candidates = try await tab.reviewerCandidates(matching: "")
        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { $0.kind == .user })
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
}
