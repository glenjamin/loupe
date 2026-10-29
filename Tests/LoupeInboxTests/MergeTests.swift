@testable import LoupeFakeGitHub
import Foundation
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct MergeTests {
    @Test(arguments: [
        MergeCase("CLEAN", "APPROVED", expect: .ready),
        MergeCase("HAS_HOOKS", "APPROVED", expect: .ready),
        MergeCase("UNSTABLE", "APPROVED", checks: "FAILURE", expect: .ready),
        MergeCase("DIRTY", "APPROVED", mergeable: "CONFLICTING", expect: .blocked(.conflicts(base: "master"))),
        MergeCase("DIRTY", "CHANGES_REQUESTED", mergeable: "CONFLICTING", expect: .blocked(.conflicts(base: "master"))),
        MergeCase("CLEAN", "REVIEW_REQUIRED", expect: .blocked(.notApproved)),
        MergeCase("CLEAN", nil, expect: .blocked(.notApproved)),
        MergeCase("BLOCKED", "REVIEW_REQUIRED", expect: .blocked(.notApproved)),
        MergeCase("BLOCKED", "CHANGES_REQUESTED", expect: .blocked(.changesRequested)),
        MergeCase("BLOCKED", "APPROVED", checks: "FAILURE", expect: .blocked(.checksFailing)),
        MergeCase("BLOCKED", "APPROVED", checks: "PENDING", expect: .blocked(.branchProtection)),
        // GitHub says BLOCKED for a draft, not the deprecated DRAFT. A draft's next step is
        // leaving draft, whatever else would stop it merging.
        MergeCase("BLOCKED", "APPROVED", isDraft: true, expect: .draft),
        MergeCase("BLOCKED", "REVIEW_REQUIRED", checks: "FAILURE", isDraft: true, expect: .draft),
        MergeCase("DIRTY", "CHANGES_REQUESTED", mergeable: "CONFLICTING", isDraft: true, expect: .draft),
        MergeCase("DRAFT", "APPROVED", expect: .draft),
        MergeCase("BEHIND", "APPROVED", expect: .blocked(.behind(base: "master"))),
        MergeCase("UNKNOWN", "APPROVED", mergeable: "UNKNOWN", expect: .checking),
    ])
    func theButtonFollowsGitHubsMergeStateAndTheReviewDecision(_ merge: MergeCase) async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.edit(pullRequest.id) {
            $0.reviewDecision = merge.reviewDecision
            $0.isDraft = merge.isDraft
        }
        try await app.github.setMergeState(of: pullRequest.id, merge.state, mergeable: merge.mergeable)
        try await app.github.setChecks(of: pullRequest.id, state: merge.checks, [])
        let tab = try await app.open(pullRequest)

        await app.tabs.lists.refresh()
        #expect(tab.mergeReadiness == merge.expected)

        // Next launch shows the same from the store, before GitHub is asked.
        let nextRun = try #require(app.relaunch().tab(id: pullRequest.id))
        #expect(nextRun.mergeReadiness == merge.expected)
    }

    @Test func aPullRequestAboveAnOpenOneInItsStackCantBeMergedUntilTheBottomIs() async throws {
        let app = try await MergeApp()
        let (bottom, top) = try await app.mergeableStack()
        let tab = try await app.open(try #require(app.tabs.lists.pullRequest(id: top)))

        // GitHub would merge it, but merging it would merge #277 below it too.
        #expect(tab.mergeFirst?.number == 277)
        #expect(tab.mergeReadiness == .blocked(.stacked(on: 277, cascades: true)))
        await tab.merge()
        #expect(await app.github.asyncMergesReceived.isEmpty)
        #expect(await app.github.mergesReceived.isEmpty)
        #expect(tab.pullRequest.state == .open)

        // The bottom of the stack has nothing to merge first.
        let bottomTab = try await app.open(try #require(app.tabs.lists.pullRequest(id: bottom)))
        #expect(bottomTab.mergeFirst == nil)
        #expect(bottomTab.mergeReadiness == .ready)

        // Once it's merged, the PR above is the bottom and can be merged.
        try await app.github.merge(bottom)
        await app.tabs.lists.refresh()
        #expect(tab.mergeFirst == nil)
        #expect(tab.mergeReadiness == .ready)
    }

    @Test func aPullRequestOnAnotherByBranchAloneIsBlockedToo() async throws {
        let app = try await MergeApp()
        let below = try await app.github.openPullRequest(number: 940, by: FakeGitHub.viewer)
        let above = try await app.github.openPullRequest(number: 941, by: FakeGitHub.viewer)
        try await app.github.stack(above.id, on: below.id, linked: false)
        try await app.github.edit(above.id) { $0.reviewDecision = "APPROVED" }
        try await app.github.setMergeState(of: above.id, "CLEAN")
        await app.tabs.lists.refresh()
        let tab = try await app.open(try #require(app.tabs.lists.pullRequest(id: above.id)))

        #expect(tab.mergeReadiness == .blocked(.stacked(on: 940, cascades: false)))
        await tab.merge()
        #expect(await app.github.mergesReceived.isEmpty)
    }

    @Test func theBottomOfAStackMergesInTheBackgroundWithTheHeadLookedUpAndShowsMergedOnceDone() async throws {
        let app = try await MergeApp()
        let (bottom, top) = try await app.mergeableStack()
        let tab = try await app.open(try #require(app.tabs.lists.pullRequest(id: bottom)))
        let head = try await app.github.head(of: bottom)
        await app.github.setAsyncMergeRuns(2)

        let merging = Task { await tab.merge() }
        try await app.delay.untilWaiting()
        #expect(tab.isMerging, "the merge slot says it's merging while GitHub works")
        #expect(tab.pullRequest.state == .open)
        #expect(await app.github.asyncMergesReceived == [AsyncMergeInput(sha: head, merge_method: "merge", merge_action: "direct_merge")])
        #expect(await app.github.mergesReceived.isEmpty, "GitHub refuses a stacked PR through GraphQL")
        try await app.letTimePass(until: merging)

        let polls = await app.github.asyncMergePolls
        #expect(polls.count == 3, "asked after until it's done")
        #expect(Set(polls).count == 1)
        #expect(app.delay.sleeps.count { $0 == .seconds(1) } == 3, "a second before each ask")
        #expect(tab.pullRequest.state == .merged)
        #expect(tab.mergeReadiness == nil)
        #expect(!tab.isMerging)
        #expect(tab.mergeError == nil)
        #expect(app.tabs.lists.pullRequests(in: .mine, includingClosed: true, includingStale: true).first { $0.id == bottom }?.state == .merged)
        // The PR above is now the bottom of its stack, so can be merged next.
        let above = try #require(app.tabs.lists.pullRequest(id: top))
        #expect(above.state == .open)
        #expect(app.tabs.lists.stacks.bottom(under: above) == nil)
    }

    @Test func aBackgroundMergeGitHubCantDoShowsItsMessageAndLeavesThePullRequestOpen() async throws {
        let app = try await MergeApp()
        let (bottom, _) = try await app.mergeableStack()
        let tab = try await app.open(try #require(app.tabs.lists.pullRequest(id: bottom)))

        // A conflict found as GitHub merges, after the lists last looked.
        try await app.github.setMergeState(of: bottom, "DIRTY", mergeable: "CONFLICTING")
        let merging = Task { await tab.merge() }
        try await app.letTimePass(until: merging)

        #expect(tab.mergeError == "Couldn't merge: Merge conflict: the pull request could not be merged.")
        #expect(tab.pullRequest.state == .open)
        #expect(!tab.isMerging)
    }

    @Test func aBackgroundMergeOfAHeadPushedToSinceItWasSeenIsCancelled() async throws {
        let app = try await MergeApp()
        let (bottom, _) = try await app.mergeableStack()
        let tab = try await app.open(try #require(app.tabs.lists.pullRequest(id: bottom)))
        let seen = try await app.github.head(of: bottom)

        try await app.github.edit(bottom) { $0.headRefOid = String(repeating: "f", count: 40) }
        let merging = Task { await tab.merge() }
        try await app.letTimePass(until: merging)

        #expect(await app.github.asyncMergesReceived.map(\.sha) == [seen])
        #expect(try #require(tab.mergeError).contains("cancelled"))
        #expect(tab.pullRequest.state == .open)
    }

    @Test func aStackedMergeIsRefusedWhenGitHubShowsAnOpenPullRequestBelowItThatWasntKnown() async throws {
        let app = try await MergeApp()
        let (bottom, top) = try await app.mergeableStack()
        // Last seen closed, so the PR above looked like the bottom of the stack.
        try await app.github.edit(bottom) { $0.state = "CLOSED"; $0.closedAt = Date.now.formatted(.iso8601) }
        await app.tabs.lists.refresh()
        let tab = try await app.open(try #require(app.tabs.lists.pullRequest(id: top)))
        #expect(tab.mergeReadiness == .ready)

        try await app.github.edit(bottom) { $0.state = "OPEN"; $0.closedAt = nil }
        await tab.merge()

        #expect(await app.github.asyncMergesReceived.isEmpty, "nothing merged that wasn't seen")
        #expect(try #require(tab.mergeError).contains("Merge #277 first"))
        #expect(tab.mergeReadiness == .blocked(.stacked(on: 277, cascades: true)))
        #expect(tab.pullRequest.state == .open)
    }

    @Test func aBackgroundMergeStillRunningWhenLoupeStopsAskingSaysSo() async throws {
        let app = try await MergeApp()
        let (bottom, _) = try await app.mergeableStack()
        let tab = try await app.open(try #require(app.tabs.lists.pullRequest(id: bottom)))
        await app.github.setAsyncMergeRuns(.max)
        let lookups = await app.github.pullRequestLookups.count

        let merging = Task { await tab.merge() }
        try await app.letTimePass(until: merging)

        #expect(try #require(tab.mergeError).contains("hasn't finished merging"))
        #expect(!tab.isMerging)
        #expect(await app.github.pullRequestLookups.dropFirst(lookups).contains([bottom]), "looked up, as it may have landed")
    }

    @Test func anApprovalNoticedOnGitHubMakesItMergeableWithoutWaitingForTheLists() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.edit(pullRequest.id) { $0.reviewDecision = "REVIEW_REQUIRED" }
        try await app.github.setMergeState(of: pullRequest.id, "BLOCKED")
        try await app.github.setChecks(of: pullRequest.id, state: "SUCCESS", [])
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()
        #expect(tab.mergeReadiness == .blocked(.notApproved))
        _ = await app.tabs.watchForChanges()

        // GitHub works out that the approval unblocks it, but doesn't count that as an update.
        try await app.github.edit(pullRequest.id) { $0.reviewDecision = "APPROVED" }
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        _ = await app.tabs.watchForChanges()

        #expect(tab.mergeReadiness == .ready)
        #expect(await app.github.statusLookups.last == [pullRequest.id], "only the open PR, not the lists")
    }

    @Test func mergingMakesAMergeCommitOfTheHeadLookedUpAndShowsThePullRequestMerged() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()
        #expect(tab.mergeReadiness == .ready)
        let lookups = await app.github.pullRequestLookups.count
        let statusLookups = await app.github.statusLookups.count

        await tab.merge()

        #expect(await app.github.mergesReceived == [
            MergeInput(pullRequestId: pullRequest.id, mergeMethod: "MERGE", expectedHeadOid: try await app.github.head(of: pullRequest.id)),
        ])
        #expect(await app.github.asyncMergesReceived.isEmpty, "only a stacked PR merges in the background")
        #expect(await app.github.pullRequestLookups.dropFirst(lookups) == [[pullRequest.id]], "looked up again at once")
        #expect(await app.github.statusLookups.dropFirst(statusLookups) == [[pullRequest.id]], "its merge commit's checks too")
        #expect(tab.pullRequest.state == .merged)
        #expect(tab.mergeReadiness == nil, "nothing left to merge")
        #expect(!tab.isMerging)
        #expect(tab.mergeError == nil)
        #expect(!app.tabs.lists.pullRequests(in: .mine, includingStale: true).contains { $0.id == pullRequest.id })
        #expect(app.tabs.lists.pullRequests(in: .mine, includingClosed: true, includingStale: true).first { $0.id == pullRequest.id }?.state == .merged)
    }

    @Test func anOpenTabFollowsItsMergeCommitsChecksUntilTheyFinish() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()
        await tab.merge()

        try await app.github.setMergeCommitChecks(of: pullRequest.id, state: "PENDING", [.status("ci/circleci: test", "PENDING")])
        await app.tabs.watchMergeCommits()
        #expect(tab.pullRequest.mergeCommitChecks == .pending)

        try await app.github.setMergeCommitChecks(of: pullRequest.id, state: "FAILURE", [.status("ci/circleci: test", "FAILURE")])
        await app.tabs.watchMergeCommits()
        #expect(tab.pullRequest.mergeCommitChecks == .failure)
        #expect(tab.pullRequest.mergeCommitCheckContexts.failedCheckNames == ["test"])

        // Finished, they're not asked about again.
        let asked = await app.github.statusLookups.count
        await app.tabs.watchMergeCommits()
        #expect(await app.github.statusLookups.count == asked)
    }

    @Test func aClosedTabsMergeCommitIsNotFollowed() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()
        await tab.merge()
        app.tabs.close(pullRequest.id)

        let asked = await app.github.statusLookups.count
        await app.tabs.watchMergeCommits()
        #expect(await app.github.statusLookups.count == asked)
    }

    @Test func aMergeGitHubRefusesSaysWhyAndLeavesThePullRequestOpen() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()

        // Pushed to after the last lookup, so the head merged would be one nobody has seen.
        try await app.github.edit(pullRequest.id) { $0.headRefOid = String(repeating: "f", count: 40) }
        await tab.merge()

        let error = try #require(tab.mergeError)
        #expect(error.contains("Head branch was modified"))
        #expect(await app.github.mergesReceived.map(\.expectedHeadOid) == [pullRequest.headRefOid])
        #expect(tab.pullRequest.state == .open)
        #expect(tab.mergeReadiness == .ready)

        // Once the new head is looked up, merging it goes through and clears the reason.
        await app.tabs.lists.refresh()
        await tab.merge()
        #expect(tab.mergeError == nil)
        #expect(tab.pullRequest.state == .merged)
    }

    @Test func aBlockedPullRequestIsNotSentToGitHub() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.setMergeState(of: pullRequest.id, "DIRTY", mergeable: "CONFLICTING")
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()

        await tab.merge()
        #expect(await app.github.mergesReceived.isEmpty)
        #expect(tab.pullRequest.state == .open)
    }

    @Test func markingADraftReadyForReviewTakesItOutOfDraftAndOffersTheMerge() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.edit(pullRequest.id) { $0.isDraft = true }
        try await app.github.setMergeState(of: pullRequest.id, "BLOCKED")
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()
        #expect(tab.mergeReadiness == .draft)

        await tab.merge()
        #expect(await app.github.mergesReceived.isEmpty, "a draft isn't merged")

        await tab.markReadyForReview()

        #expect(await app.github.readyForReviewReceived == [pullRequest.id])
        #expect(!tab.pullRequest.isDraft)
        // GitHub works out afresh whether it can merge, rather than keeping the draft's BLOCKED.
        #expect(tab.mergeReadiness == .checking)
        #expect(!tab.isMerging)
        #expect(tab.mergeError == nil)

        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        await app.tabs.lists.refresh()
        #expect(tab.mergeReadiness == .ready)
    }

    @Test func readyForReviewGitHubRefusesSaysWhyAndLeavesItADraft() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.edit(pullRequest.id) { $0.isDraft = true }
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()

        // As when the viewer loses access to the repo after the last lookup.
        await app.github.delete(pullRequest.id)
        await tab.markReadyForReview()

        let error = try #require(tab.mergeError)
        #expect(error.contains("Could not resolve to a node"))
        #expect(tab.pullRequest.isDraft)
        #expect(tab.mergeReadiness == .draft)
        #expect(!tab.isMerging)
    }

    @Test func onlyADraftIsMarkedReadyForReview() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()

        await tab.markReadyForReview()
        #expect(await app.github.readyForReviewReceived.isEmpty)
    }

    @Test func someoneElsesPullRequestTheViewerHasntApprovedOffersNoMerge() async throws {
        let app = try await MergeApp()
        let pullRequest = app.conversation.toReview[0]
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        let tab = try await app.open(pullRequest)
        try await app.conversation.conversations.review("CHANGES_REQUESTED", by: FakeGitHub.viewer, on: pullRequest.id, commit: try await app.github.head(of: pullRequest.id))
        await tab.reload()
        await app.tabs.lists.refresh()

        #expect(tab.mergeReadiness == nil)
        #expect(tab.approvedMergeReadiness == nil, "not without the viewer's approval")
        #expect(!tab.isReadyToMerge)
    }

    @Test func someoneElsesPullRequestTheViewerApprovedCanBeMergedLikeTheirOwn() async throws {
        let app = try await MergeApp()
        let pullRequest = app.conversation.toReview[0]
        try await app.github.setMergeState(of: pullRequest.id, "BLOCKED")
        let tab = try await app.open(pullRequest)
        let head = try await app.github.head(of: pullRequest.id)
        try await app.conversation.conversations.review("APPROVED", by: FakeGitHub.viewer, on: pullRequest.id, commit: head)
        await tab.reload()
        await app.tabs.lists.refresh()
        #expect(tab.mergeReadiness == nil, "the merge box stays the author's")
        #expect(tab.approvedMergeReadiness == .blocked(.notApproved), "GitHub still wants its approvals")

        try await app.github.edit(pullRequest.id) { $0.reviewDecision = "APPROVED" }
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        await app.tabs.lists.refresh()
        #expect(tab.approvedMergeReadiness == .ready)

        await tab.merge()
        #expect(await app.github.mergesReceived == [
            MergeInput(pullRequestId: pullRequest.id, mergeMethod: "MERGE", expectedHeadOid: head),
        ])
        #expect(tab.pullRequest.state == .merged)
        #expect(tab.approvedMergeReadiness == nil, "nothing left to merge")
    }
}

/// A merge state and review decision from GitHub, and the button they should give.
struct MergeCase: Sendable, CustomTestStringConvertible {
    let state: String
    let reviewDecision: String?
    let mergeable: String
    let checks: String
    let isDraft: Bool
    let expected: MergeReadiness

    init(_ state: String, _ reviewDecision: String?, mergeable: String = "MERGEABLE", checks: String = "SUCCESS", isDraft: Bool = false, expect expected: MergeReadiness) {
        self.state = state
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.checks = checks
        self.isDraft = isDraft
        self.expected = expected
    }

    var testDescription: String {
        "\(state), \(reviewDecision ?? "no review decision"), checks \(checks)\(isDraft ? ", draft" : "")"
    }
}

/// `ConversationApp` with PR tabs whose merges reach the fake GitHub holding the PRs, so a
/// merge shows in the lists' next lookup as it would on GitHub.
@MainActor
private struct MergeApp {
    let conversation: ConversationApp
    let tabs: TabsModel

    init() async throws {
        conversation = try await ConversationApp()
        tabs = Self.tabs(conversation)
        await tabs.lists.refresh()
    }

    var github: FakeGitHub { conversation.github }
    var delay: ManualDelay { conversation.delay }

    /// The viewer's own approved PR into master that the tests merge.
    func mergeable() throws -> PullRequestSummary {
        try #require(tabs.lists.pullRequests(in: .mine, includingStale: true).first { $0.repository == "tamarinworks/gazette" && $0.number == 272 })
    }

    /// The ids of the viewer's captured GitHub stack, gazette #277 with #278 on it, both
    /// approved and mergeable on GitHub, as the lists have seen them.
    func mergeableStack() async throws -> (bottom: String, top: String) {
        try await github.addCapturedStack()
        let (bottom, top) = ("PR_kwDOAYVX-88AAAABI4ybXQ", "PR_kwDOAYVX-88AAAABI5AxRA")
        for id in [bottom, top] {
            try await github.edit(id) { $0.reviewDecision = "APPROVED" }
            try await github.setMergeState(of: id, "CLEAN")
        }
        await tabs.lists.refresh()
        return (bottom, top)
    }

    /// Lets each wait pass as soon as it starts, such as between asks after a background merge,
    /// until `task` is done.
    func letTimePass(until task: Task<Void, Never>) async throws {
        let finished = Finished()
        Task { await task.value; finished.value = true }
        while !finished.value {
            try await until { finished.value || delay.isWaiting }
            delay.elapse()
        }
    }

    /// Opens the PR's tab and lets it learn who the viewer is.
    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        try await conversation.conversations.add(pullRequest.id)
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }

    /// Fresh models over the same store, as on the next launch.
    func relaunch() -> TabsModel {
        Self.tabs(conversation)
    }

    private static func tabs(_ app: ConversationApp) -> TabsModel {
        let lists = PullRequestListModel(client: app.github.client(), store: app.store, checkoutSearchRoots: [], onOpen: { _ in })
        let transport = MergeTransport(github: app.github, details: app.details)
        return .manuallyTimed(lists: lists, store: app.store, client: GitHubClient(token: { FakeGitHub.validToken }, transport: transport), notifications: app.github.notifications(), delay: app.delay, showDelay: app.showDelay)
    }
}

/// Sends merges and leaving draft to the GitHub holding the PRs and everything else a tab asks
/// to the details.
private struct MergeTransport: HTTPTransport {
    let github: FakeGitHub
    let details: FakePullRequestDetails

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let changesThePullRequest = body.contains("mergePullRequest(") || body.contains("markPullRequestReadyForReview(")
            || request.url?.path().contains("/merge-async") == true
        return changesThePullRequest ? try await github.send(request) : try await details.send(request)
    }
}

/// Whether a task has finished, for a test to check while it waits.
@MainActor
private final class Finished {
    var value = false
}
