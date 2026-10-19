import Foundation
import LoupeInbox
import LoupeModel
import Testing

@MainActor
struct ViewerVerdictTests {
    @Test func anApprovalOfTheHeadShowsWithNoChangesSinceAndApprovingStillWorks() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.approve(pullRequest, on: first)
        let tab = try await app.open(pullRequest)

        let verdict = try #require(tab.viewerVerdict)
        #expect(verdict.state == .approved)
        #expect(verdict.commitOid == first)
        #expect(verdict.submittedAt != nil)
        #expect(verdict.since == .unchanged && verdict.isCurrent)

        // Nothing is held back by it: approving again goes to GitHub as before.
        #expect(tab.canReview && tab.canSubmitReview(as: .approve))
        await tab.submitReview(as: .approve)
        #expect(await app.conversations.reviewMutationsReceived == [
            .addReview(pullRequestId: tab.id, commitId: first, body: nil, event: "APPROVE", threads: []),
        ])
        #expect(tab.viewerVerdict?.isCurrent == true)
    }

    @Test func commitsPushedSinceAnApprovalAreCounted() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.approve(pullRequest, on: first)
        let tab = try await app.open(pullRequest)

        _ = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest)
        _ = try await app.pushCommit(["notes.md": "Notes\n"], to: pullRequest)
        #expect(tab.viewerVerdict?.since == .changed, "moved on, but not counted until the new commits are diffed")

        await tab.reload()
        let verdict = try #require(tab.viewerVerdict)
        #expect(verdict.state == .approved && verdict.commitOid == first)
        #expect(verdict.since == .commits(2))
        #expect(!verdict.isCurrent)
        #expect(tab.canSubmitReview(as: .approve))
    }

    @Test func anApprovalOfAHeadForcePushedAwayHasChangedSince() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.approve(pullRequest, on: first)
        try await app.repo.git(["commit", "--quiet", "--amend", "-m", "Say hey, amended"], in: app.repo.contributorDirectory)
        try await app.forcePush(pullRequest)
        let tab = try await app.open(pullRequest)

        let verdict = try #require(tab.viewerVerdict)
        #expect(verdict.commitOid == first)
        #expect(verdict.since == .changed, "the approved commit isn't in the PR any more, so there's nothing to count")
    }

    @Test func approvingShowsAtOnceAndIsKeptWhereverThePullRequestIsShown() async throws {
        let app = try await SinceApp()
        await app.conversations.decideReviews(on: app.github)
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.conversations.review("COMMENTED", by: FakeGitHub.viewer, on: pullRequest.id, commit: first)
        let tab = try await app.open(pullRequest)
        #expect(tab.viewerVerdict == nil, "a comment isn't a verdict")

        await app.conversations.hold(.submit)
        let submitting = Task { await tab.submitReview(as: .approve) }
        await app.conversations.arrival(of: .submit)

        let sending = try #require(tab.viewerVerdict, "approved before GitHub answers")
        #expect(sending.state == .approved && sending.commitOid == first && sending.since == .unchanged)
        #expect(try app.store.conversation(of: tab.id)?.viewerReview?.state == .approved, "stored as it's shown")

        await app.conversations.release(.submit)
        await submitting.value

        #expect(tab.reviewDraft.error == nil)
        #expect(tab.viewerVerdict?.state == .approved && tab.viewerVerdict?.since == .unchanged, "as GitHub has it once fetched")
        let row = try #require(app.tabs.lists.pullRequest(id: tab.id))
        #expect(app.tabs.lists.verdict(on: row, in: .toReview) == .approved, "the list's row says so too")
        let mark = try #require(app.tabs.lists.reviewMark(on: row, in: .toReview))
        #expect(mark.kind == .approved && !mark.isUpdated)
        #expect(row.viewerReviewCommitOid == first && mark.givenAt != nil)

        let nextRun = app.relaunch()
        await nextRun.lists.refresh()
        let checked = try #require(nextRun.lists.pullRequest(id: tab.id))
        #expect(nextRun.lists.reviewMark(on: checked, in: .toReview)?.isUpdated == false, "as the refresh's check finds it")
        nextRun.open(pullRequest)
        #expect(nextRun.tab(id: tab.id)?.viewerVerdict?.state == .approved, "from the stored conversation")
    }

    @Test func aRefusedApprovalPutsBackTheVerdictThereWas() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.conversations.review("CHANGES_REQUESTED", by: FakeGitHub.viewer, on: pullRequest.id, commit: first)
        let tab = try await app.open(pullRequest)
        #expect(tab.viewerVerdict?.state == .changesRequested && tab.viewerVerdict?.since == .unchanged)

        await app.conversations.refuseThreadChanges()
        await app.conversations.hold(.submit)
        let submitting = Task { await tab.submitReview(as: .approve) }
        await app.conversations.arrival(of: .submit)
        #expect(tab.viewerVerdict?.state == .approved)
        await app.conversations.release(.submit)
        await submitting.value

        #expect(tab.reviewDraft.error != nil)
        #expect(tab.viewerVerdict?.state == .changesRequested)
        #expect(tab.viewerVerdict?.commitOid == first)
        #expect(try app.store.conversation(of: tab.id)?.viewerReview?.state == .changesRequested)
        #expect(tab.canSubmitReview(as: .approve), "free to try again")
    }

    @Test func theListsRowSaysWhetherThePullRequestHasChangedSinceTheViewersVerdict() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.github.review(pullRequest.id, "APPROVED", commit: first)
        await app.tabs.lists.refresh()

        var row = try #require(app.tabs.lists.pullRequest(id: pullRequest.id))
        #expect(app.tabs.lists.verdict(on: row, in: .toReview) == .approved)
        #expect(app.tabs.lists.reviewMark(on: row, in: .toReview)?.isUpdated == false)

        _ = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest)
        row = try #require(app.tabs.lists.pullRequest(id: pullRequest.id))
        let mark = try #require(app.tabs.lists.reviewMark(on: row, in: .toReview))
        #expect(mark.kind == .approved)
        guard case .commits(1, _) = try #require(mark.updates.first) else {
            Issue.record("expected one commit since, got \(mark.updates)")
            return
        }
    }
}

private extension SinceApp {
    /// The viewer approves the PR on `commit` on github.com, as the conversation and the lists'
    /// check both see it.
    func approve(_ pullRequest: PullRequestSummary, on commit: String) async throws {
        try await conversations.review("APPROVED", by: FakeGitHub.viewer, on: pullRequest.id, commit: commit)
        try await github.review(pullRequest.id, "APPROVED", commit: commit)
        await tabs.lists.refresh()
    }
}
