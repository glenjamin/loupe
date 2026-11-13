@testable import LoupeFakeGitHub
import LoupeInbox
import LoupeModel
import Testing

/// Who a comment box's `@` offers to mention, as github.com's does.
@MainActor
struct MentionsTests {
    @Test func thoseTakingPartInThePullRequestComeFirstThenTheReposPeopleAndTeamsNeverTheViewer() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        try await app.conversations.add(pullRequest.id)
        _ = await app.conversations.comment("<p>Looks odd</p>", on: pullRequest.id, by: "octocat")
        try await app.conversations.review("COMMENTED", by: "kit-vance", on: pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        let participants = tab.mentionCandidates.map(\.login)
        #expect(participants.prefix(3) == ["rowan-ashby", "kit-vance", "octocat"], "the author, then the latest first")
        #expect(participants.contains("pat-barrow"), "asked to review")

        await tab.fetchMentionCandidates()
        #expect(tab.mentionCandidates.map(\.login) == participants + [
            "jules-hollis", "tam-fairweather", "eharcourt", "tamarinworks/devs", "tamarinworks/on-call", "tamarinworks/package-update-reviewers",
        ], "the repo's people and teams after, never the viewer")
        #expect(tab.mentionCandidates[1].name == "Kit Vance", "named from the repo's people")
        #expect(Mentions.matches(tab.mentionCandidates, for: "devs").map(\.login) == ["tamarinworks/devs"])
    }
}
