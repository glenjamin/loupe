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

    @Test func mergingMakesAMergeCommitOfTheHeadLookedUpAndShowsThePullRequestMerged() async throws {
        let app = try await MergeApp()
        let pullRequest = try app.mergeable()
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()
        #expect(tab.mergeReadiness == .ready)
        let lookups = await app.github.pullRequestLookups.count

        await tab.merge()

        #expect(await app.github.mergesReceived == [
            MergeInput(pullRequestId: pullRequest.id, mergeMethod: "MERGE", expectedHeadOid: try await app.github.head(of: pullRequest.id)),
        ])
        #expect(await app.github.pullRequestLookups.dropFirst(lookups) == [[pullRequest.id]], "looked up again at once")
        #expect(tab.pullRequest.state == .merged)
        #expect(tab.mergeReadiness == nil, "nothing left to merge")
        #expect(!tab.isMerging)
        #expect(tab.mergeError == nil)
        #expect(!app.tabs.lists.pullRequests(in: .mine).contains { $0.id == pullRequest.id })
        #expect(app.tabs.lists.pullRequests(in: .mine, includingClosed: true).first { $0.id == pullRequest.id }?.state == .merged)
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

    @Test func someoneElsesPullRequestOffersNoMerge() async throws {
        let app = try await MergeApp()
        let pullRequest = app.conversation.toReview[0]
        try await app.github.setMergeState(of: pullRequest.id, "CLEAN")
        let tab = try await app.open(pullRequest)
        await app.tabs.lists.refresh()

        #expect(tab.mergeReadiness == nil)
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

    /// The viewer's own approved PR into master that the tests merge.
    func mergeable() throws -> PullRequestSummary {
        try #require(tabs.lists.pullRequests(in: .mine).first { $0.repository == "tamarinworks/gazette" && $0.number == 272 })
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
        return TabsModel(lists: lists, store: app.store, client: GitHubClient(token: { FakeGitHub.validToken }, transport: transport), notifications: app.github.notifications())
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
        return changesThePullRequest ? try await github.send(request) : try await details.send(request)
    }
}
