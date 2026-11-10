@testable import LoupeFakeGitHub
import Foundation
import LoupeInbox
import LoupeModel
import Testing

@MainActor
struct RenameTests {
    @Test func renamingSendsTheTitleAndTheListsFollowAtOnce() async throws {
        let app = try await ConversationApp()
        let (tab, pullRequest) = try await app.openMine()
        #expect(tab.canRename)

        #expect(await tab.rename(to: "  A clearer title\n"))

        #expect(await app.conversations.updatesReceived == [.init(pullRequestId: pullRequest.id, title: "A clearer title")])
        #expect(tab.pullRequest.title == "A clearer title")
        #expect(app.mine.first { $0.id == pullRequest.id }?.title == "A clearer title")
        #expect(try app.relaunch().lists.pullRequest(id: pullRequest.id)?.title == "A clearer title", "stored")
        #expect(tab.renameError == nil)
    }

    @Test func aRefusedRenameKeepsTheTitleAndSaysWhy() async throws {
        let app = try await ConversationApp()
        let (tab, pullRequest) = try await app.openMine()
        await app.conversations.refuseEdits()

        #expect(await !tab.rename(to: "A clearer title"))

        #expect(tab.pullRequest.title == pullRequest.title)
        #expect(tab.renameError?.contains("Resource not accessible") == true)
        tab.clearRenameError()
        #expect(tab.renameError == nil)
    }

    @Test func aBlankOrUnchangedTitleIsntSent() async throws {
        let app = try await ConversationApp()
        let (tab, pullRequest) = try await app.openMine()

        #expect(await !tab.rename(to: "   "))
        #expect(await tab.rename(to: pullRequest.title))

        #expect(await app.conversations.updatesReceived.isEmpty)
        #expect(tab.pullRequest.title == pullRequest.title)
    }

    @Test func someoneElsesPullRequestCantBeRenamed() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        #expect(!tab.canRename)
        #expect(await !tab.rename(to: "Not mine to name"))
        #expect(await app.conversations.updatesReceived.isEmpty)
    }
}
