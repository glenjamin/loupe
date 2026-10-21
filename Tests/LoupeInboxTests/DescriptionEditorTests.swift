@testable import LoupeFakeGitHub
import Foundation
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct DescriptionEditorTests {
    @Test func editingStartsFromTheDescriptionAsItIsOnGitHubNow() async throws {
        let app = try await ConversationApp()
        let (tab, pullRequest) = try await app.openMine()
        let stored = try #require(tab.conversation?.body)
        // Edited in a browser since the conversation was fetched, which keeps its line endings.
        try await app.conversations.editBody("Added on github.com\r\n\r\n![screenshot](https://github.com/user-attachments/assets/1)", on: pullRequest.id)

        #expect(tab.canEditDescription)
        await tab.editDescription()

        let editor = try #require(tab.descriptionEditor)
        #expect(editor.phase == .editing)
        #expect(editor.draft == "Added on github.com\n\n![screenshot](https://github.com/user-attachments/assets/1)")
        #expect(tab.conversation?.body == stored, "the stored copy isn't what's edited")
        #expect(!editor.hasChanges)
        #expect(!editor.canSave, "nothing to save until the text changes")

        editor.draft += "\n\nMore"
        #expect(editor.canSave)
        editor.draft = editor.original
        #expect(!editor.canSave)
    }

    @Test func savingSendsTheDescriptionThenShowsGitHubsRenderingOfIt() async throws {
        let app = try await ConversationApp()
        let (tab, pullRequest) = try await app.openMine()
        await tab.editDescription()
        let editor = try #require(tab.descriptionEditor)

        editor.draft = "Rewritten <em>by hand</em>\n\nSecond paragraph"
        await tab.saveDescription()

        #expect(await app.conversations.updatesReceived == [.init(pullRequestId: pullRequest.id, body: "Rewritten <em>by hand</em>\n\nSecond paragraph")])
        #expect(tab.descriptionEditor == nil)
        let conversation = try #require(tab.conversation)
        #expect(conversation.body == "Rewritten <em>by hand</em>\n\nSecond paragraph")
        #expect(conversation.bodyHTML == "<p dir=\"auto\">Rewritten &lt;em&gt;by hand&lt;/em&gt;</p>\n<p dir=\"auto\">Second paragraph</p>", "GitHub's rendering, fetched afresh")
        #expect(try app.store.conversation(of: pullRequest.id) == conversation)
    }

    @Test func aRefusedSaveKeepsTheDraftAndSaysWhy() async throws {
        let app = try await ConversationApp()
        let (tab, pullRequest) = try await app.openMine()
        let before = tab.conversation
        await app.conversations.refuseEdits()
        await tab.editDescription()
        let editor = try #require(tab.descriptionEditor)

        editor.draft = "A careful rewrite"
        await tab.saveDescription()

        #expect(tab.descriptionEditor === editor, "still open")
        #expect(editor.phase == .editing)
        #expect(editor.draft == "A careful rewrite")
        #expect(editor.canSave, "so it can be tried again")
        #expect(editor.saveError?.contains("Resource not accessible") == true)
        #expect(tab.conversation == before)
        #expect(await app.conversations.body(of: pullRequest.id) == before?.body)
    }

    @Test func aDescriptionThatCantBeFetchedIsntOfferedForEditing() async throws {
        let app = try await ConversationApp()
        let (tab, _) = try await app.openMine()
        await app.conversations.fail()
        await tab.editDescription()

        let editor = try #require(tab.descriptionEditor)
        guard case let .fetchFailed(message) = editor.phase else {
            Issue.record("expected the fetch to fail, got \(editor.phase)")
            return
        }
        #expect(message.contains("502"))
        #expect(!editor.canSave)

        await app.conversations.recover()
        await editor.fetch()
        #expect(editor.phase == .editing)
        #expect(editor.draft == tab.conversation?.body)
    }

    @Test func cancellingDropsTheDraft() async throws {
        let app = try await ConversationApp()
        let (tab, _) = try await app.openMine()
        await tab.editDescription()
        tab.descriptionEditor?.draft = "Never mind"

        tab.closeDescriptionEditor()
        #expect(tab.descriptionEditor == nil)
        await tab.editDescription()
        #expect(tab.descriptionEditor?.draft == tab.conversation?.body)
        #expect(await app.conversations.updatesReceived.isEmpty)
    }

    @Test func someoneElsesPullRequestOffersNoEditing() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        #expect(!tab.canEditDescription)
        await tab.editDescription()
        #expect(tab.descriptionEditor == nil)
    }
}

private extension ConversationApp {
    /// Opens the viewer's first PR, with the probe's conversation, and waits for it to load.
    func openMine() async throws -> (PullRequestTab, PullRequestSummary) {
        let pullRequest = mine[0]
        try await conversations.add(pullRequest.id)
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return (tab, pullRequest)
    }
}
