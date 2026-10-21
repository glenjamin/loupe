@testable import LoupeFakeGitHub
import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import Testing

/// Comments on one commit's own changes, as github.com takes them from a PR's commit view, and
/// comments on a range of lines, on the whole PR's diff or a commit's.
@MainActor
struct CommitCommentTests {
    @Test func aCommentOnACommitsLinePostsOnThatCommitAndShowsThereAndOnThePullRequest() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let tab = try await app.open(pullRequest)
        let commit = try #require(tab.ready?.commits.first { $0.headline == "Change app.go" })
        await tab.show(.commit(commit.oid))
        let file = try #require(tab.file("app.go"))
        #expect(tab.commentTarget?.commitOid == commit.oid && tab.commentTarget?.isWholePullRequest == false)
        #expect(tab.commentTarget?.takesDeletedLines == true, "its parent is the PR's base")
        #expect(tab.commentableAnchors(of: file)?.contains(DiffAnchor(path: "app.go", side: .left, line: 10)) == true)

        let anchor = DiffAnchor(path: "app.go", side: .right, line: 11)
        tab.startComment(at: anchor)
        let comment = try #require(tab.shownNewComment)
        #expect(!comment.target.takesReviewComments, "GitHub's pending reviews hold comments on the PR's head alone")
        comment.draft.text = "Why a second line?"
        await tab.sendReviewComment()
        #expect(await app.conversations.reviewMutationsReceived.isEmpty, "nothing goes into a review from a commit")
        await tab.sendComment()

        #expect(await app.conversations.commentsReceived == [.init(
            repository: pullRequest.repository, number: pullRequest.number, body: "Why a second line?", commitId: commit.oid,
            path: "app.go", line: 11, side: "RIGHT"
        )])
        let threads = try #require(tab.threads(on: tab.expandedFile(file)))
        let thread = try #require(threads.anchored.first { $0.line == 11 }?.threads.first)
        #expect(threads.anchored.map(\.line) == [11], "on the commit, on the line it was made on")
        #expect(thread.originalCommitOid == commit.oid)
        #expect(tab.placedLines(of: thread) == 11...11)

        await tab.show(.all)
        let wholeFile = try #require(tab.file("app.go"))
        let whole = try #require(tab.threads(on: tab.expandedFile(wholeFile)))
        #expect(whole.anchored.flatMap(\.threads).isEmpty)
        #expect(whole.elsewhere.map(\.id) == [thread.id], "outdated on the whole PR's diff, as GitHub said")

        let stored = try #require(try app.store.conversation(of: pullRequest.id)?.threads.first { $0.id == thread.id })
        #expect(stored.originalCommitOid == commit.oid, "kept with the conversation")
    }

    @Test func aCommitShowsOnlyThreadsMadeOnItOnTheLinesTheyWereMadeOnAndTheyTakeReplies() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let id = pullRequest.id
        let onHead = try await app.conversations.startThread(on: id, path: "app.go", line: 11, body: "Why three?")
        let commit = try #require(try await app.open(pullRequest).ready?.commits.first { $0.headline == "Change app.go" })
        app.tabs.close(id)
        let onCommit = try await app.conversations.startThread(
            on: id, path: "app.go", line: 12, startLine: 10, commit: commit.oid, outdated: true, body: "These three could be one."
        )
        let deleted = try await app.conversations.startThread(on: id, path: "app.go", line: 50, side: "LEFT", commit: commit.oid, outdated: true, body: "Gone?")
        let tab = try await app.open(pullRequest)

        await tab.show(.commit(commit.oid))
        let file = tab.expandedFile(try #require(tab.file("app.go")))
        let threads = try #require(tab.threads(on: file))
        #expect(threads.anchored.map(\.line) == [12, 50])
        #expect(threads.anchored.flatMap(\.threads).map(\.id) == [onCommit, deleted], "not the one made on the head")
        #expect(threads.elsewhere.isEmpty, "the rest belong to the whole PR's diff")
        let range = try #require(tab.reviewThread(onCommit))
        #expect(tab.placedLines(of: range) == 10...12)
        #expect(tab.suggestedLines(for: range) == ["10a", "10b", "10c"])

        tab.startReply(to: range)
        try #require(tab.threadActivity.replies[onCommit]).text = "Agreed."
        await tab.sendReply(to: range)
        #expect(await app.conversations.repliesReceived.map(\.body) == ["Agreed."])
        #expect(tab.reviewThread(onCommit)?.comments.count == 2)

        await tab.show(.all)
        let wholeFile = try #require(tab.file("app.go"))
        let whole = try #require(tab.threads(on: tab.expandedFile(wholeFile)))
        #expect(whole.anchored.flatMap(\.threads).map(\.id) == [onHead])
        #expect(Set(whole.elsewhere.map(\.id)) == [onCommit, deleted])

        let later = try #require(tab.ready?.commits.last)
        await tab.show(.commit(later.oid))
        #expect(tab.commentTarget?.takesDeletedLines == false, "its parent isn't the PR's base, whose numbers GitHub gives deleted lines")
        #expect(tab.threads(on: try #require(tab.file("new.go")))?.isEmpty == true)
    }

    @Test func aSelectionOfLinesInOneHunkStartsACommentOnThemAllAndPostsItsFirstLine() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let file = tab.expandedFile(try #require(tab.file("app.go")))
        let end = DiffAnchor(path: "app.go", side: .right, line: 12)
        let start = DiffAnchor(path: "app.go", side: .left, line: 10)

        tab.startComment(at: end, from: start)
        let comment = try #require(tab.shownNewComment)
        #expect(comment.start == start)
        #expect(tab.commentedAnchors(of: file) == [start, DiffAnchor(path: "app.go", side: .right, line: 10), DiffAnchor(path: "app.go", side: .right, line: 11), end])
        comment.draft.text = "Could these be one?"
        await tab.sendComment()

        let sent = try #require(await app.conversations.commentsReceived.last)
        #expect(sent.commitId == tab.ready?.headOid)
        #expect((sent.startLine, sent.startSide, sent.line, sent.side) == (10, "LEFT", 12, "RIGHT"))
        let thread = try #require(tab.threads(on: file)?.anchored.first { $0.line == 12 }?.threads.last)
        #expect(thread.startSide == .left && thread.side == .right)
        #expect(tab.placedLines(of: thread) == 10...12)
    }

    @Test func aSelectionGitHubCantTakeAsARangeStartsACommentOnTheClickedLine() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        defer { withExtendedLifetime(app) {} }
        let end = DiffAnchor(path: "app.go", side: .right, line: 12)

        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 49), from: end)
        #expect(tab.shownNewComment?.start == nil, "across two hunks")
        #expect(tab.shownNewComment?.anchor.line == 49)
        tab.cancelComment()

        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 9), from: end)
        #expect(tab.shownNewComment?.start == nil, "ending before it starts")
        tab.cancelComment()

        let file = try #require(tab.file("app.go"))
        await tab.expandContext(of: file, ContextExpansion(hunk: 0, direction: .above))
        tab.startComment(at: end, from: DiffAnchor(path: "app.go", side: .right, line: 3))
        #expect(tab.shownNewComment?.start == nil, "from a revealed line, which isn't in the PR's diff")
        #expect(tab.commentedAnchors(of: tab.expandedFile(file)) == [end])
    }

    @Test func aRangeOnACommitGoesIntoNoReviewAndARangeOnTheWholeDiffCanStartOne() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 11), from: DiffAnchor(path: "app.go", side: .right, line: 9))
        try #require(tab.shownNewComment).draft.text = "Start here"
        await tab.sendReviewComment()
        guard case let .addReview(_, commitId, _, _, threads)? = await app.conversations.reviewMutationsReceived.first else {
            Issue.record("expected a review to be started")
            return
        }
        #expect(commitId == tab.ready?.headOid)
        #expect(threads == [.init(path: "app.go", line: 11, side: "RIGHT", body: "Start here", startLine: 9, startSide: "RIGHT")])

        // A comment started on a commit stays with it, and isn't shown on other changes.
        let commit = try #require(tab.ready?.commits.first)
        await tab.show(.commit(commit.oid))
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 11))
        await tab.show(.all)
        #expect(tab.shownNewComment == nil)
        #expect(tab.commentedAnchors(of: tab.expandedFile(try #require(tab.file("app.go")))).isEmpty)
    }
}
