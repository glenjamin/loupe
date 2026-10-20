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
        #expect(tab.suggestedLines(on: DiffAnchor(path: "app.go", side: .right, line: 11)) == ["10b"], "an added line")
        #expect(tab.suggestedLines(on: DiffAnchor(path: "app.go", side: .right, line: 9)) == ["9 line"], "an unchanged line")
        #expect(tab.suggestedLines(on: DiffAnchor(path: "app.go", side: .left, line: 50)) == nil, "github.com offers none on a deleted line")
        #expect(tab.suggestedLines(on: DiffAnchor(path: "app.go", side: .right, line: 30)) == nil, "a line the diff doesn't show")

        let file = try #require(tab.file("app.go"))
        await tab.expandContext(of: file, ContextExpansion(hunk: 1, direction: .above))
        #expect(tab.suggestedLines(on: DiffAnchor(path: "app.go", side: .right, line: 30)) == ["28 line"], "a line revealed around a hunk, two below its old number")
        #expect(await app.conversations.commentsReceived.isEmpty)
    }

    @Test func aNewCommentOnSeveralLinesSuggestsFromEachOfThemOnTheNewSide() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        defer { withExtendedLifetime(app) {} }
        // From the unchanged line before the change, across the line taken out, to its last.
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 12), from: DiffAnchor(path: "app.go", side: .right, line: 9))
        #expect(tab.suggestedLines(for: try #require(tab.threadActivity.newComment)) == ["9 line", "10a", "10b", "10c"])
        tab.cancelComment()
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 12), from: DiffAnchor(path: "app.go", side: .left, line: 10))
        #expect(tab.suggestedLines(for: try #require(tab.threadActivity.newComment)) == ["10a", "10b", "10c"], "from a deleted line, its new lines")
        tab.cancelComment()

        let commit = try #require(tab.ready?.commits.first { $0.headline == "Change app.go" })
        await tab.show(.commit(commit.oid))
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 11), from: DiffAnchor(path: "app.go", side: .right, line: 10))
        #expect(tab.suggestedLines(for: try #require(tab.threadActivity.newComment)) == ["10a", "10b"], "the commit's own lines")
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

        // On a commit's own changes the thread's made on the head, so it has no lines there.
        await tab.show(.commit(try #require(tab.ready?.commits.first).oid))
        #expect(tab.suggestedLines(for: try #require(tab.thread(range))) == nil)
    }
}

extension PullRequestTab {
    /// What a suggestion in a new comment on `anchor` alone starts from, as it's started there.
    func suggestedLines(on anchor: DiffAnchor) -> [String]? {
        defer { cancelComment() }
        startComment(at: anchor)
        return threadActivity.newComment.flatMap(suggestedLines(for:))
    }
}
