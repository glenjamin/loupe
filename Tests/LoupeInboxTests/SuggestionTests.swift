import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import Testing

/// What a suggestion in a comment on lines of the diff starts from: the lines' text on the new
/// side, as the PR's diff has it.
@MainActor
struct SuggestionTests {
    @Test func aNewCommentSuggestsFromItsLineOnTheNewSideAndNotOnADeletedLine() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        #expect(tab.suggestedLines(at: DiffAnchor(path: "app.go", side: .right, line: 11)) == ["10b"], "an added line")
        #expect(tab.suggestedLines(at: DiffAnchor(path: "app.go", side: .right, line: 9)) == ["9 line"], "an unchanged line")
        #expect(tab.suggestedLines(at: DiffAnchor(path: "app.go", side: .left, line: 50)) == nil, "github.com offers none on a deleted line")
        #expect(tab.suggestedLines(at: DiffAnchor(path: "app.go", side: .right, line: 30)) == nil, "a line the diff doesn't show")

        let file = try #require(tab.file("app.go"))
        await tab.expandContext(of: file, ContextExpansion(hunk: 1, direction: .above))
        #expect(tab.suggestedLines(at: DiffAnchor(path: "app.go", side: .right, line: 30)) == ["28 line"], "a line revealed around a hunk, two below its old number")
        #expect(await app.conversations.commentsReceived.isEmpty)
    }

    @Test func aReplySuggestsFromEveryLineOfItsThreadOnTheNewSide() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let id = pullRequest.id
        let single = try await app.conversations.startThread(on: id, path: "app.go", line: 11, body: "Why three?")
        let range = try await app.conversations.startThread(on: id, path: "app.go", line: 12, startLine: 9, body: "All of these?")
        let deleted = try await app.conversations.startThread(on: id, path: "app.go", line: 50, side: "LEFT", body: "Keep this?")
        let outdated = try await app.conversations.startThread(on: id, path: "app.go", line: 3, outdated: true, body: "Gone now")
        let onFile = try await app.conversations.startThread(on: id, path: "app.go", line: nil, body: "The whole file")
        let tab = try await app.open(pullRequest)

        #expect(tab.suggestedLines(for: try #require(tab.thread(single))) == ["10b"])
        #expect(tab.suggestedLines(for: try #require(tab.thread(range))) == ["9 line", "10a", "10b", "10c"])
        #expect(tab.suggestedLines(for: try #require(tab.thread(deleted))) == nil, "on deleted lines")
        #expect(tab.suggestedLines(for: try #require(tab.thread(outdated))) == nil, "no current lines")
        #expect(tab.suggestedLines(for: try #require(tab.thread(onFile))) == nil, "on no lines")

        // It's the whole PR's diff, whichever changes are shown, as threads belong to it.
        await tab.show(.commit(try #require(tab.ready?.commits.last).oid))
        #expect(tab.suggestedLines(for: try #require(tab.thread(range))) == ["9 line", "10a", "10b", "10c"])
    }
}
