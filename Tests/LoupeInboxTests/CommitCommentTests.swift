@testable import LoupeFakeGitHub
import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import Testing

/// Comments on one commit's own changes, as github.com takes them from a PR's commit view, posted
/// at once or into a review, and comments on a range of lines, on the whole PR's diff or a
/// commit's.
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
        try #require(tab.shownNewComment).draft.text = "Why a second line?"
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

    @Test func aCommentOnACommitsLineStartsAReviewOnTheHeadAndIsPlacedWhereGitHubsDiffUpToTheCommitHasIt() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let tab = try await app.open(pullRequest)
        let commit = try #require(tab.ready?.commits.first { $0.headline == "Change app.go" })
        await tab.show(.commit(commit.oid))

        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 11))
        let comment = try #require(tab.shownNewComment)
        #expect(comment.takesReviewComments)
        comment.draft.text = "Why a second line?"
        await tab.sendReviewComment()

        let mutations = await app.conversations.reviewMutationsReceived
        guard case let .addReview(_, commitId, _, event, threads)? = mutations.first, case let .addCommitComment(reviewId, onCommit, path, position, body)? = mutations.last else {
            Issue.record("expected an empty review, then the comment on the commit: \(mutations)")
            return
        }
        #expect(mutations.count == 2)
        #expect(commitId == tab.ready?.headOid && event == nil && threads.isEmpty, "a review is of the head")
        #expect(reviewId == tab.pendingReview?.id)
        #expect((onCommit, path, position, body) == (commit.oid, "app.go", 6, "Why a second line?"), "three context lines, the old line 10, then 10a and 10b")
        let file = tab.expandedFile(try #require(tab.file("app.go")))
        let thread = try #require(tab.threads(on: file)?.anchored.first { $0.line == 11 }?.threads.first)
        #expect(thread.comments.map(\.isPending) == [true])
        #expect(thread.originalCommitOid == commit.oid)
        #expect(tab.threadActivity.newCommentError == nil)

        tab.startComment(at: DiffAnchor(path: "app.go", side: .left, line: 50))
        try #require(tab.shownNewComment).draft.text = "Gone?"
        await tab.sendReviewComment()
        guard case let .addCommitComment(_, _, _, position, _)? = await app.conversations.reviewMutationsReceived.last else {
            Issue.record("expected the comment on the commit")
            return
        }
        #expect(position == 15, "the second hunk's header counts as a line, then three context lines")
        #expect(await app.conversations.reviewMutationsReceived.count == 3, "into the review started, not another")
        #expect(tab.threads(on: tab.expandedFile(try #require(tab.file("app.go"))))?.anchored.map(\.line) == [11, 50])
    }

    @Test func whileAReviewIsPendingNothingPostsAtOnceAndARangeOnACommitCantBeSent() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        try await app.conversations.startPendingReview(on: pullRequest.id, path: "app.go", line: 11, body: "Hmm")
        let tab = try await app.open(pullRequest)
        let commit = try #require(tab.ready?.commits.first { $0.headline == "Change app.go" })
        await tab.show(.commit(commit.oid))

        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 12), from: DiffAnchor(path: "app.go", side: .right, line: 10))
        let comment = try #require(tab.shownNewComment)
        #expect(comment.start != nil && !comment.takesReviewComments, "GitHub places a comment on a commit in a review by one line")
        comment.draft.text = "These three could be one."
        await tab.sendReviewComment()
        await tab.sendComment()
        #expect(await app.conversations.reviewMutationsReceived.isEmpty)
        #expect(await app.conversations.commentsReceived.isEmpty, "GitHub refuses a comment at once while a review is pending")
        #expect(tab.shownNewComment?.draft.text == "These three could be one.", "kept to send once the review's done")
    }

    @Test func aSingleCommentGitHubRefusesForAReviewStartedElsewhereSaysWhy() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let tab = try await app.open(pullRequest)
        try await app.conversations.startPendingReview(on: pullRequest.id, path: "app.go", line: 11, body: "From the browser")

        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 12))
        try #require(tab.shownNewComment).draft.text = "Why?"
        await tab.sendComment()
        #expect(await app.conversations.commentsReceived.count == 1)
        #expect(tab.shownNewComment?.draft.text == "Why?", "opened again to add to the review instead")
        #expect(tab.threadActivity.newCommentError?.hasPrefix("Couldn't comment: GitHub returned HTTP 422: Validation Failed (user_id can only have one pending review per pull request)") == true)
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

    @Test func aDragOverTheGutterAsksWhichLinesARangeCanTake() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        defer { withExtendedLifetime(app) {} }
        let start = DiffAnchor(path: "app.go", side: .right, line: 9)
        let end = DiffAnchor(path: "app.go", side: .right, line: 12)

        let lines = try #require(tab.commentRange(from: start, to: end))
        #expect(lines.first == start && lines.last == end)
        #expect(lines.contains(DiffAnchor(path: "app.go", side: .left, line: 10)), "the deleted line between")
        #expect(tab.commentRange(from: end, to: start) == nil, "ending before it starts")
        #expect(tab.commentRange(from: end, to: DiffAnchor(path: "app.go", side: .right, line: 49)) == nil, "across two hunks")

        let file = try #require(tab.file("app.go"))
        await tab.expandContext(of: file, ContextExpansion(hunk: 0, direction: .above))
        #expect(tab.commentRange(from: DiffAnchor(path: "app.go", side: .right, line: 3), to: end) == nil, "from a revealed line")
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
