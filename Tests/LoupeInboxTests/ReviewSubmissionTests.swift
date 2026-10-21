@testable import LoupeFakeGitHub
import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import Testing

@MainActor
struct ReviewSubmissionTests {
    @Test func startingAReviewFromALineHoldsTheCommentPendingAndTheNextJoinsIt() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        #expect(tab.canReview && tab.pendingReview == nil)

        try await comment("Is anything still using this?", at: DiffAnchor(path: "app.go", side: .left, line: 50), on: tab)

        let head = try #require(tab.ready?.headOid)
        let reviewId = try #require(await app.conversations.pendingReviewId(of: tab.id))
        #expect(await app.conversations.reviewMutationsReceived == [
            .addReview(pullRequestId: tab.id, commitId: head, body: nil, event: nil, threads: [.init(path: "app.go", line: 50, side: "LEFT", body: "Is anything still using this?")]),
        ])
        #expect(await app.conversations.commentsReceived.isEmpty, "nothing posted at once")
        #expect(tab.threadActivity.newComment == nil)
        #expect(tab.pendingReview == PendingReview(id: reviewId, body: "", commentCount: 1))
        let pending = try #require(try tab.threadsOn("app.go").anchored.first { $0.side == .left && $0.line == 50 }?.threads.first)
        #expect(pending.isPending && pending.comments.allSatisfy(\.isPending))
        #expect(tab.thread(threadId)?.isPending == false, "others' threads aren't")

        try await comment("And this name?", at: DiffAnchor(path: "app.go", side: .right, line: 12), on: tab)

        #expect(await app.conversations.reviewMutationsReceived.last == .addThread(reviewId: reviewId, .init(path: "app.go", line: 12, side: "RIGHT", body: "And this name?")))
        #expect(tab.pendingReview?.commentCount == 2)
        #expect(try tab.threadsOn("app.go").anchored.first { $0.line == 12 }?.threads.first?.isPending == true)

        // Next launch shows the review and its comments pending from the store.
        await app.conversations.fail()
        let nextRun = try #require(app.relaunch().tab(id: tab.id))
        #expect(nextRun.pendingReview == tab.pendingReview)
        #expect(nextRun.conversation?.threads == tab.conversation?.threads)
    }

    @Test func aReviewStartedElsewhereIsAddedToAndItsSummaryStartsTheDraft() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let reviewId = try await app.conversations.startPendingReview(on: pullRequest.id, path: "app.go", line: 11, body: "Why three?", summary: "Mostly fine")
        let tab = try await app.open(pullRequest)
        #expect(tab.pendingReview == PendingReview(id: reviewId, body: "Mostly fine", commentCount: 1))

        tab.startWritingSummary()
        #expect(tab.reviewDraft.body == "Mostly fine")
        tab.reviewDraft.body = "Mostly fine, one question"
        tab.startWritingSummary()
        #expect(tab.reviewDraft.body == "Mostly fine, one question", "only filled the first time")

        try await comment("Typo", at: DiffAnchor(path: "app.go", side: .right, line: 10), on: tab)
        #expect(await app.conversations.reviewMutationsReceived == [.addThread(reviewId: reviewId, .init(path: "app.go", line: 10, side: "RIGHT", body: "Typo"))])
        #expect(tab.pendingReview?.commentCount == 2)
    }

    @Test func submittingApprovesWithTheSummaryAndTheDecisionFollows() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        await app.conversations.decideReviews(on: app.github)
        try await comment("Nit: rename", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        let reviewId = try #require(tab.pendingReview?.id)

        tab.startWritingSummary()
        tab.reviewDraft.isWritingSummary = true
        tab.reviewDraft.body = "Looks good"
        await tab.submitReview(as: .approve)

        #expect(await app.conversations.reviewMutationsReceived.last == .submit(reviewId: reviewId, event: "APPROVE", body: "Looks good"))
        #expect(tab.reviewDraft.error == nil)
        #expect(!tab.reviewDraft.isWritingSummary, "closed once submitted")
        #expect(tab.pendingReview == nil)
        #expect(tab.conversation?.threads.allSatisfy { !$0.isPending } == true, "its comments are submitted")
        #expect(tab.conversation?.latestReviews.contains { $0.reviewer.login == FakeGitHub.viewer && $0.state == .approved } == true)
        #expect(tab.pullRequest.reviewDecision == .approved)
        #expect(app.tabs.lists.pullRequest(id: tab.id)?.reviewDecision == .approved, "the list's row too")
        #expect(tab.reviewDraft.body.isEmpty, "ready for the next review")
    }

    @Test func submittingWithNoPendingReviewSendsOneReviewWithTheEvent() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        await app.conversations.decideReviews(on: app.github)

        #expect(tab.canSubmitReview(as: .approve), "approving needs nothing more")
        #expect(!tab.canSubmitReview(as: .requestChanges), "asking for changes needs a summary")
        #expect(!tab.canSubmitReview(as: .comment), "so does submitting without a verdict")
        tab.reviewDraft.body = "Please split this up"
        #expect(tab.canSubmitReview(as: .requestChanges) && tab.canSubmitReview(as: .comment))
        await tab.submitReview(as: .requestChanges)

        let head = try #require(tab.ready?.headOid)
        #expect(await app.conversations.reviewMutationsReceived == [
            .addReview(pullRequestId: tab.id, commitId: head, body: "Please split this up", event: "REQUEST_CHANGES", threads: []),
        ])
        #expect(tab.pendingReview == nil)
        #expect(tab.pullRequest.reviewDecision == .changesRequested)
    }

    @Test func pendingCommentsAreEnoughToSubmitWithoutAVerdict() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        try await comment("Nit: rename", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        let reviewId = try #require(tab.pendingReview?.id)
        #expect(tab.canSubmitReview(as: .comment) && tab.canSubmitReview(as: .requestChanges))

        await tab.submitReview(as: .comment)

        #expect(await app.conversations.reviewMutationsReceived.last == .submit(reviewId: reviewId, event: "COMMENT", body: ""))
        #expect(tab.pendingReview == nil)
    }

    @Test func aPendingReviewsSummaryIsSentWhenTheSummaryWasNeverOpened() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let reviewId = try await app.conversations.startPendingReview(on: pullRequest.id, path: "app.go", line: 11, body: "Why three?", summary: "Mostly fine")
        let tab = try await app.open(pullRequest)

        await tab.submitReview(as: .approve)

        #expect(await app.conversations.reviewMutationsReceived.last == .submit(reviewId: reviewId, event: "APPROVE", body: "Mostly fine"))
    }

    @Test func discardingDeletesTheReviewAndAllItsComments() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let before = tab.conversation?.threads.map(\.id)
        try await comment("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        try await comment("And here", at: DiffAnchor(path: "app.go", side: .right, line: 12), on: tab)
        let reviewId = try #require(tab.pendingReview?.id)
        tab.reviewDraft.body = "Half-written"
        #expect(tab.unresolvedThreadCount(of: "app.go") == 3)

        await tab.discardReview()

        #expect(await app.conversations.reviewMutationsReceived.last == .delete(reviewId: reviewId))
        #expect(tab.pendingReview == nil)
        #expect(tab.conversation?.threads.map(\.id) == before, "the review's threads go with it")
        #expect(try tab.threadsOn("app.go").anchored.allSatisfy { $0.threads.allSatisfy { !$0.isPending } })
        #expect(tab.unresolvedThreadCount(of: "app.go") == 1)
        #expect(tab.reviewDraft.body.isEmpty)
        #expect(try app.store.conversation(of: tab.id)?.pendingReview == nil)
    }

    @Test func deletingAPendingCommentTakesItsThreadFromTheDiffAndTheCountDrops() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        try await comment("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        try await comment("And here", at: DiffAnchor(path: "app.go", side: .right, line: 12), on: tab)
        let reviewId = try #require(tab.pendingReview?.id)
        let thread = try #require(try tab.threadsOn("app.go").anchored.first { $0.line == 11 }?.threads.first { $0.isPending })
        let comment = try #require(thread.comments.first)

        await tab.deletePendingComment(comment, in: thread)

        #expect(await app.conversations.reviewMutationsReceived.last == .deleteComment(id: comment.id))
        #expect(tab.threadActivity.errors[thread.id] == nil && tab.threadActivity.deleting.isEmpty)
        #expect(tab.pendingReview == PendingReview(id: reviewId, body: "", commentCount: 1), "the review stays, with its other comment")
        #expect(tab.reviewThread(thread.id) == nil, "its only comment gone, so is the thread")
        #expect(try tab.threadsOn("app.go").anchored.contains { $0.line == 11 && $0.threads.contains { $0.isPending } } == false)
        #expect(try tab.threadsOn("app.go").anchored.first { $0.line == 12 }?.threads.first?.isPending == true)
        #expect(tab.unresolvedThreadCount(of: "app.go") == 2)
        #expect(try app.store.conversation(of: tab.id)?.pendingReview?.commentCount == 1)
    }

    @Test func deletingTheLastPendingCommentDiscardsTheEmptiedReviewButKeepsTheSummaryBeingWritten() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        try await comment("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        let reviewId = try #require(tab.pendingReview?.id)
        tab.reviewDraft.body = "Half-written"
        let thread = try #require(tab.placedThreads.first { $0.isPending })

        await tab.deletePendingComment(try #require(thread.comments.first), in: thread)

        #expect(await app.conversations.reviewMutationsReceived.suffix(2) == [.deleteComment(id: thread.comments[0].id), .delete(reviewId: reviewId)])
        #expect(tab.pendingReview == nil, "GitHub would keep it, pending with nothing in it")
        #expect(!tab.placedThreads.contains { $0.isPending })
        #expect(tab.reviewDraft.body == "Half-written", "the summary waits for the next review")
    }

    @Test func aPendingReviewWithASavedSummaryIsKeptWhenItsLastCommentIsDeleted() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let reviewId = try await app.conversations.startPendingReview(on: pullRequest.id, path: "app.go", line: 11, body: "Why three?", summary: "Mostly fine")
        let tab = try await app.open(pullRequest)
        let thread = try #require(tab.placedThreads.first { $0.isPending })

        await tab.deletePendingComment(try #require(thread.comments.first), in: thread)

        #expect(await app.conversations.reviewMutationsReceived == [.deleteComment(id: thread.comments[0].id)])
        #expect(tab.pendingReview == PendingReview(id: reviewId, body: "Mostly fine", commentCount: 0))
    }

    @Test func thePendingCommentsAreListedInDiffOrderWithWhatTheyAnswerAndChoosingOneShowsIt() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let theirs = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 11, body: "Why three?")
        try await app.conversations.replyInPendingReview(to: theirs, on: pullRequest.id, body: "Room for growth")
        let tab = try await app.open(pullRequest)
        try await comment("Package docs?", at: DiffAnchor(path: "new.go", side: .right, line: 1), on: tab)
        try await comment("Is this still used?", at: DiffAnchor(path: "app.go", side: .left, line: 50), on: tab)
        try await comment("And this name?", at: DiffAnchor(path: "app.go", side: .right, line: 12), on: tab)

        let pending = tab.pendingComments
        #expect(pending.map { "\($0.thread.path):\($0.thread.line ?? 0)" } == ["app.go:11", "app.go:12", "app.go:50", "new.go:1"])
        #expect(pending.count == tab.pendingReview?.commentCount)
        #expect(pending[0].replyingTo?.author?.login == "octocat" && pending[0].replyingTo?.bodyHTML.contains("Why three?") == true)
        #expect(pending[0].comment.bodyHTML.contains("Room for growth") && pending[0].commentedCode == nil)
        #expect(pending[1].replyingTo == nil && pending[1].commentedCode == "new app.go", "a new thread names its line of code")

        let chosen = pending[3]
        await tab.follow(ThreadLink(.show, thread: chosen.thread.id))
        #expect(tab.selectedFile == "new.go")
        #expect(tab.threadActivity.revealing == chosen.thread.id)
    }

    @Test func aRefusedDeleteLeavesTheCommentAndSaysWhy() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        try await comment("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        let thread = try #require(tab.placedThreads.first { $0.isPending })
        await app.conversations.refuseThreadChanges()

        await tab.deletePendingComment(try #require(thread.comments.first), in: thread)

        #expect(tab.threadActivity.errors[thread.id]?.contains("Resource not accessible") == true)
        #expect(tab.threadActivity.deleting.isEmpty)
        #expect(tab.reviewThread(thread.id) == thread, "still there, as it was")
        #expect(tab.placedThreads.contains(thread))
        #expect(tab.pendingReview?.commentCount == 1)
    }

    @Test func aRefusalSaysWhyAndKeepsTheDraft() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        try await comment("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        await app.conversations.refuseThreadChanges()

        tab.reviewDraft.body = "Looks good"
        await tab.submitReview(as: .approve)

        #expect(tab.reviewDraft.error?.contains("Resource not accessible") == true)
        #expect(tab.reviewDraft.body == "Looks good")
        #expect(tab.pendingReview?.commentCount == 1, "still pending")
        #expect(!tab.reviewDraft.isSubmitting)

        // A comment refused on its way into the review stays open, saying why.
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 12))
        let draft = try #require(tab.threadActivity.newComment?.draft)
        draft.text = "Another"
        await tab.sendReviewComment()
        #expect(tab.threadActivity.newComment?.draft === draft)
        #expect(tab.threadActivity.newCommentError?.contains("Resource not accessible") == true)
    }

    @Test func aReviewStartedSinceElsewhereIsFoundWhenGitHubRefusesASecond() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let reviewId = try await app.conversations.startPendingReview(on: tab.id, path: "app.go", line: 10, body: "From the browser")
        #expect(tab.pendingReview == nil, "not yet known")

        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 12))
        let draft = try #require(tab.threadActivity.newComment?.draft)
        draft.text = "From Loupe"
        await tab.sendReviewComment()
        #expect(tab.threadActivity.newCommentError?.contains("one pending review") == true)
        #expect(tab.pendingReview?.id == reviewId, "found on refusal")

        await tab.sendReviewComment()
        #expect(tab.threadActivity.newComment == nil)
        #expect(await app.conversations.reviewMutationsReceived.last == .addThread(reviewId: reviewId, .init(path: "app.go", line: 12, side: "RIGHT", body: "From Loupe")))
    }

    @Test func theViewerReviewsTheirOwnPullRequestWithCommentsAndSubmitsItAsAComment() async throws {
        let app = try await ThreadsApp()
        let tab = try await app.open(try await app.pushPullRequest(in: .mine))
        #expect(tab.isOwnPullRequest && tab.canStartReview && !tab.canReview)

        try await comment("Explain this in the description", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        let reviewId = try #require(tab.pendingReview?.id)
        try await comment("Left over from a spike", at: DiffAnchor(path: "app.go", side: .left, line: 50), on: tab)

        let head = try #require(tab.ready?.headOid)
        #expect(await app.conversations.reviewMutationsReceived == [
            .addReview(pullRequestId: tab.id, commitId: head, body: nil, event: nil, threads: [.init(path: "app.go", line: 11, side: "RIGHT", body: "Explain this in the description")]),
            .addThread(reviewId: reviewId, .init(path: "app.go", line: 50, side: "LEFT", body: "Left over from a spike")),
        ], "held in a pending review, with no verdict")
        #expect(await app.conversations.commentsReceived.isEmpty, "nothing posted at once")
        #expect(tab.pendingReview?.commentCount == 2)
        #expect(tab.pendingComments.map { "\($0.thread.path):\($0.thread.line ?? 0)" } == ["app.go:11", "app.go:50"])

        #expect(tab.canSubmitReview(as: .comment))
        #expect(!tab.canSubmitReview(as: .approve) && !tab.canSubmitReview(as: .requestChanges), "GitHub refuses either from the author")
        await tab.submitReview(as: .approve)
        #expect(await app.conversations.reviewMutationsReceived.count == 2, "not sent")

        tab.reviewDraft.body = "Notes for reviewers"
        await tab.submitReview(as: .comment)

        #expect(await app.conversations.reviewMutationsReceived.last == .submit(reviewId: reviewId, event: "COMMENT", body: "Notes for reviewers"))
        #expect(tab.reviewDraft.error == nil)
        #expect(tab.pendingReview == nil)
        #expect(tab.conversation?.threads.allSatisfy { !$0.isPending } == true, "its comments are submitted")
    }

    @Test func aVerdictGitHubRefusesFromTheAuthorSaysWhyAndKeepsTheReviewPending() async throws {
        // GitHub knows the PR as the viewer's though the list doesn't yet, so Loupe offers Approve.
        let app = try await ThreadsApp()
        let listed = try #require(app.tabs.lists.pullRequests(in: .toReview).first)
        try await app.conversations.add(listed.id, number: listed.number, author: FakeGitHub.viewer)
        let reviewId = try await app.conversations.startPendingReview(on: listed.id, path: "app.go", line: 11, body: "Why three?")
        let tab = try await app.open(listed)
        #expect(tab.canReview)

        tab.reviewDraft.body = "LGTM"
        await tab.submitReview(as: .approve)

        #expect(await app.conversations.reviewMutationsReceived == [.submit(reviewId: reviewId, event: "APPROVE", body: "LGTM")])
        #expect(tab.reviewDraft.error?.contains("Can not approve your own pull request") == true)
        #expect(tab.reviewDraft.body == "LGTM")
        #expect(tab.pendingReview?.id == reviewId, "still pending")
    }

    @Test func onlyAnOpenPullRequestTakesAReviewAndOnlySomeoneElsesAVerdict() async throws {
        let app = try await ThreadsApp()
        let (mine, toReview) = (try #require(app.tabs.lists.pullRequests(in: .mine, includingStale: true).first), try #require(app.tabs.lists.pullRequests(in: .toReview).first))
        try await app.conversations.add(mine.id, author: FakeGitHub.viewer)
        try await app.conversations.add(toReview.id)
        let (own, theirs) = (try await app.open(mine), try await app.open(toReview))
        #expect(own.canStartReview && !own.canReview)
        #expect(theirs.canStartReview && theirs.canReview)

        try await app.github.merge(own.id)
        try await app.github.edit(theirs.id) { $0.state = "CLOSED"; $0.closedAt = Date.now.formatted(.iso8601) }
        try await app.tabs.lists.checkForChanges(to: [own.id, theirs.id])

        #expect(own.pullRequest.state == .merged && !own.canStartReview && !own.canReview)
        #expect(theirs.pullRequest.state == .closed && !theirs.canStartReview && !theirs.canReview)
    }

    /// Writes a comment under `anchor` and adds it to the viewer's review, starting one if need be.
    private func comment(_ text: String, at anchor: DiffAnchor, on tab: PullRequestTab) async throws {
        tab.startComment(at: anchor)
        let draft = try #require(tab.threadActivity.newComment?.draft)
        draft.text = text
        await tab.sendReviewComment()
        #expect(tab.threadActivity.newCommentError == nil)
    }
}

extension PullRequestTab {
    /// The threads on a file to review in the whole PR's diff.
    func threadsOn(_ path: String) throws -> FileThreads {
        let shown = try #require(file(path))
        return try #require(threads(on: shown))
    }
}
