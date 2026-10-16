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

        tab.startFinishingReview()
        #expect(tab.reviewDraft.body == "Mostly fine")
        tab.reviewDraft.body = "Mostly fine, one question"
        tab.startFinishingReview()
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

        tab.startFinishingReview()
        tab.reviewDraft.body = "Looks good"
        tab.reviewDraft.event = .approve
        await tab.submitReview()

        #expect(await app.conversations.reviewMutationsReceived.last == .submit(reviewId: reviewId, event: "APPROVE", body: "Looks good"))
        #expect(tab.reviewDraft.error == nil)
        #expect(tab.pendingReview == nil)
        #expect(tab.conversation?.threads.allSatisfy { !$0.isPending } == true, "its comments are submitted")
        #expect(tab.conversation?.latestReviews.contains { $0.reviewer.login == FakeGitHub.viewer && $0.state == .approved } == true)
        #expect(tab.pullRequest.reviewDecision == .approved)
        #expect(app.tabs.lists.pullRequest(id: tab.id)?.reviewDecision == .approved, "the list's row too")
        #expect(tab.reviewDraft.body.isEmpty && tab.reviewDraft.event == .comment, "ready for the next review")
    }

    @Test func submittingWithNoPendingReviewSendsOneReviewWithTheEvent() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        await app.conversations.decideReviews(on: app.github)

        tab.reviewDraft.event = .requestChanges
        #expect(!tab.canSubmitReview, "asking for changes needs a summary")
        tab.reviewDraft.body = "Please split this up"
        #expect(tab.canSubmitReview)
        await tab.submitReview()

        let head = try #require(tab.ready?.headOid)
        #expect(await app.conversations.reviewMutationsReceived == [
            .addReview(pullRequestId: tab.id, commitId: head, body: "Please split this up", event: "REQUEST_CHANGES", threads: []),
        ])
        #expect(tab.pendingReview == nil)
        #expect(tab.pullRequest.reviewDecision == .changesRequested)

        tab.reviewDraft.event = .approve
        #expect(tab.canSubmitReview, "approving needs nothing more")
    }

    @Test func abandoningDeletesTheReviewAndItsComments() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let before = tab.conversation?.threads.map(\.id)
        try await comment("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        let reviewId = try #require(tab.pendingReview?.id)
        tab.reviewDraft.body = "Half-written"
        #expect(tab.unresolvedThreadCount(of: "app.go") == 2)

        await tab.abandonReview()

        #expect(await app.conversations.reviewMutationsReceived.last == .delete(reviewId: reviewId))
        #expect(tab.pendingReview == nil)
        #expect(tab.conversation?.threads.map(\.id) == before, "the review's thread goes with it")
        #expect(tab.unresolvedThreadCount(of: "app.go") == 1)
        #expect(tab.reviewDraft.body.isEmpty)
        #expect(try app.store.conversation(of: tab.id)?.pendingReview == nil)
    }

    @Test func aRefusalSaysWhyAndKeepsTheDraft() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        try await comment("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        await app.conversations.refuseThreadChanges()

        tab.reviewDraft.body = "Looks good"
        tab.reviewDraft.event = .approve
        await tab.submitReview()

        #expect(tab.reviewDraft.error?.contains("Resource not accessible") == true)
        #expect(tab.reviewDraft.body == "Looks good" && tab.reviewDraft.event == .approve)
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

    @Test func theViewersOwnPullRequestOffersNoReview() async throws {
        let app = try await ThreadsApp()
        let own = try #require(app.tabs.lists.pullRequests(in: .mine).first)
        try await app.conversations.add(own.id)
        let tab = try await app.open(own)

        #expect(tab.isOwnPullRequest && !tab.canReview)
        tab.reviewDraft.body = "LGTM"
        tab.reviewDraft.event = .approve
        #expect(!tab.canSubmitReview)
        await tab.submitReview()
        #expect(await app.conversations.reviewMutationsReceived.isEmpty)
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
