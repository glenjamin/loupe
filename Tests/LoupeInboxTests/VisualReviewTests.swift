@testable import LoupeFakeGitHub
import Foundation
import LoupeInbox
import LoupeModel
import Testing

@MainActor
struct VisualReviewTests {
    @Test func aPullRequestWithCIsDiffBookCommentOffersItsReport() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        let markdown = try diffBookComment()
        await app.conversations.comment("<h3>Visual baselines changed</h3>", on: pullRequest.id, by: "tamarindeployer", markdown: markdown)

        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        let review = try #require(tab.visualReview)
        #expect(review.changeCount == 4)
        #expect(review.stories.count == 4)
        #expect(review.reportURL.lastPathComponent == "index.html")
        #expect(tab.shownSection == .conversation)
        tab.showVisualReview()
        #expect(tab.shownSection == .visualReview)

        // The markdown is stored with the conversation, so next launch offers it at once.
        await app.conversations.fail()
        let nextRun = try #require(app.relaunch().tab(id: pullRequest.id))
        #expect(nextRun.visualReview == review)
    }

    @Test func ciEditingItsCommentUpdatesTheReportOnReload() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        let markdown = try diffBookComment()
        let commentId = await app.conversations.comment("<h3>Visual baselines changed</h3>", on: pullRequest.id, by: "tamarindeployer", markdown: markdown, at: .now.addingTimeInterval(-3600))
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        let rerun = markdown
            .replacing("4 baseline(s)", with: "1 baseline(s)")
            .replacing("4 changed", with: "1 changed")
            .replacing("11111111-2222-4333-8444-555555555555", with: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")
        try await app.conversations.edit(comment: commentId, on: pullRequest.id, to: rerun, bodyHTML: "<h3>Visual baselines changed</h3>")
        await tab.reload()

        let review = try #require(tab.visualReview)
        #expect(review.counts?.changed == 1)
        #expect(review.reportURL.absoluteString.contains("bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"))
    }

    @Test func aPullRequestWithoutOneHasNoReportToShow() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        #expect(tab.visualReview == nil)
        tab.showVisualReview()
        #expect(tab.shownSection == .conversation)
    }
}

/// CI's comment as captured in `probe/diff-book-comment.json`, its ids made up.
private func diffBookComment() throws -> String {
    struct Comment: Decodable { let body: String }
    return try JSONDecoder().decode(Comment.self, from: Data(contentsOf: projectRoot.appending(path: "probe/diff-book-comment.json"))).body
}
