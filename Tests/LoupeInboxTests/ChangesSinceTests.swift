import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ChangesSinceTests {
    @Test func theChangesSinceTheViewersLastReviewCanBePickedOnceThePullRequestHasMovedOn() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.conversations.review("APPROVED", by: FakeGitHub.viewer, on: pullRequest.id, commit: first)
        let tab = try await app.open(pullRequest)
        #expect(tab.anchors.isEmpty, "reviewed at the head shown, so there's nothing since")

        let second = try await app.pushCommit(["README": "An app that says hi.\n", "app.go": "package app\n\nfunc Hello() string { return \"hi\" }\n"], to: pullRequest)
        try await app.conversations.review("COMMENTED", by: "jules-hollis", on: pullRequest.id, commit: second)
        await tab.reload()

        let anchor = try #require(tab.anchors.first)
        #expect(tab.anchors.count == 1, "another reviewer's review isn't the viewer's, and it's first opened in this tab")
        #expect(anchor.kind == .lastReview)
        #expect(anchor.oid == first)
        #expect(tab.anchorState(of: anchor) == nil, "looked at only once asked")
        await tab.prepareAnchors()
        #expect(tab.anchorState(of: anchor) == .ready)
        #expect(tab.diffStat(of: .since(anchor)) == DiffStat(files: 2, additions: 2, deletions: 2))

        tab.selectedFile = "app.go"
        await tab.show(.since(anchor))
        #expect(tab.shownChoice == .since(anchor))
        #expect(tab.shown?.files.map(\.path) == ["README", "app.go"])
        #expect(tab.file("app.go")?.hunks.flatMap(\.lines).map(\.text).contains("func Hello() string { return \"hi\" }") == true)
        #expect(tab.selectedFile == "app.go")
        #expect(tab.nextCommit == nil, "moving on goes to the next commit only from one commit's changes")
        let shownApp = try #require(tab.file("app.go"))
        #expect(tab.threads(on: shownApp) == nil, "threads belong to the whole PR's diff, as with one commit's")
        #expect(tab.commentableAnchors(of: shownApp) == nil)
        #expect(try app.store.conversation(of: pullRequest.id)?.viewerReview?.commitOid == first, "kept with the conversation")

        await tab.reload()
        #expect(tab.shownChoice == .all, "reloading goes back to the whole PR's changes")
    }

    @Test func theChangesSinceThePullRequestWasLastOpenedStayPutWhileItsTabIsOpenAndMoveOnNextTime() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        var tab = try await app.open(pullRequest)
        #expect(!tab.anchors.contains { $0.kind == .lastOpened }, "never opened before")
        app.tabs.close(pullRequest.id)

        _ = try await app.pushCommit(["README": "An app that says hi.\n"], to: pullRequest)
        tab = try await app.open(pullRequest)
        let opened = try #require(tab.anchors.first { $0.kind == .lastOpened })
        #expect(opened.oid == first)
        await tab.prepareAnchors()
        await tab.show(.since(opened))
        #expect(tab.shown?.files.map(\.path) == ["README"])

        // Reloading new commits while the tab is open keeps the head it was opened from.
        let third = try await app.pushCommit(["notes.md": "Notes\n"], to: pullRequest)
        await tab.reload()
        #expect(tab.ready?.headOid == third)
        #expect(tab.anchors.first { $0.kind == .lastOpened }?.oid == first)
        await tab.prepareAnchors()
        await tab.show(.since(opened))
        #expect(tab.shown?.files.map(\.path) == ["README", "notes.md"])

        // The next launch opens it from the head last shown.
        let fourth = try await app.pushCommit(["notes.md": "More notes\n"], to: pullRequest)
        let relaunched = app.relaunch()
        await relaunched.lists.refresh()
        relaunched.open(pullRequest)
        let restored = try #require(relaunched.tab(id: pullRequest.id))
        await restored.load()
        #expect(restored.ready?.headOid == fourth)
        let next = try #require(restored.anchors.first { $0.kind == .lastOpened })
        #expect(next.oid == third)
        #expect(next.at != nil)
        await restored.prepareAnchors()
        await restored.show(.since(next))
        #expect(restored.shown?.files.map(\.path) == ["notes.md"])
        #expect(try app.store.seenHead(of: pullRequest.id)?.headRefOid == fourth, "recorded for the launch after")
    }

    @Test func aHeadThePullRequestWasRebasedFromIsFetchedButCantBePicked() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.conversations.review("COMMENTED", by: FakeGitHub.viewer, on: pullRequest.id, commit: first)
        // Rebased before the viewer opens it, so the reviewed head was never in their checkout.
        try await app.repo.git(["commit", "--amend", "--quiet", "-m", "Say hi, rebased"], in: app.repo.contributorDirectory)
        try await app.repo.push(asPullRequest: pullRequest.number)
        let rebased = try await app.repo.git(["rev-parse", "HEAD"], in: app.repo.contributorDirectory)
        try await app.github.edit(pullRequest.id) { $0.headRefOid = rebased }
        await app.tabs.lists.refresh()
        let tab = try await app.open(pullRequest)
        #expect(try await !app.repo.has(first))
        let before = try await app.repo.checkoutState()

        let anchor = try #require(tab.anchors.first)
        #expect(anchor.oid == first)
        await tab.prepareAnchors()

        #expect(tab.anchorState(of: anchor) == .rebased)
        #expect(try await app.repo.has(first), "fetched by oid to tell")
        #expect(try await app.repo.checkoutState() == before, "the checkout is left alone")
        #expect(tab.diffStat(of: .since(anchor)) == nil)
        await tab.show(.since(anchor))
        #expect(tab.shownChoice == .all)
    }

    @Test func aHeadTheRemoteDoesntHaveSaysItCouldntBeFetched() async throws {
        let app = try await SinceApp()
        let (pullRequest, _) = try await app.pushPullRequest()
        let missing = String(repeating: "5", count: 40)
        try await app.conversations.review("APPROVED", by: FakeGitHub.viewer, on: pullRequest.id, commit: missing)
        let tab = try await app.open(pullRequest)

        let anchor = try #require(tab.anchors.first)
        #expect(anchor.oid == missing)
        await tab.prepareAnchors()

        guard case let .failed(message)? = tab.anchorState(of: anchor) else {
            Issue.record("expected the fetch to fail, got \(String(describing: tab.anchorState(of: anchor)))")
            return
        }
        #expect(message.contains("fetch"))
        await tab.show(.since(anchor))
        #expect(tab.shownChoice == .all)
    }
}

/// The app's models over the PR fixture and an in-memory store, with a conversation for each
/// PR from `FakeConversations`, and a repo whose checkout the PR is diffed from.
@MainActor
private struct SinceApp {
    let github: FakeGitHub
    let details = FakePullRequestDetails()
    let store: PullRequestStore
    let tabs: TabsModel
    let repo: FakeRepository

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        repo = try await FakeRepository()
        tabs = Self.tabs(github, details, store)
        await tabs.lists.refresh()
    }

    var conversations: FakeConversations { details.conversations }

    /// Pushes the first to-review PR, with the probe's conversation, as one commit changing
    /// `app.go`, and returns it with that commit. Its tab isn't opened, so the checkout doesn't
    /// have the commit yet.
    func pushPullRequest() async throws -> (PullRequestSummary, String) {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        try await conversations.add(listed.id, number: listed.number)
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try await repo.switchTo("feature", creatingFrom: "main")
        let first = try await repo.commit(["app.go": "package app\n\nfunc Hello() string { return \"hey\" }\n"], message: "Say hey")
        try await repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = first; $0.baseRefOid = branchPoint }
        await tabs.lists.refresh()
        return (try #require(tabs.lists.pullRequest(id: listed.id)), first)
    }

    /// Pushes a commit to the PR, on GitHub and in the repo's origin, and returns it.
    func pushCommit(_ files: [String: String], to pullRequest: PullRequestSummary) async throws -> String {
        let commit = try await repo.commit(files, message: "Another commit")
        try await repo.push(asPullRequest: pullRequest.number)
        try await github.edit(pullRequest.id) { $0.headRefOid = commit; $0.commitCount.totalCount += 1 }
        await tabs.lists.refresh()
        return commit
    }

    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }

    /// Fresh models over the same store, as on the next launch.
    func relaunch() -> TabsModel {
        Self.tabs(github, details, store)
    }

    private static func tabs(_ github: FakeGitHub, _ details: FakePullRequestDetails, _ store: PullRequestStore) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        return .manuallyTimed(lists: lists, store: store, client: details.client(), notifications: github.notifications())
    }
}

private extension PullRequestTab {
    /// The changes shown, once diffed.
    var shown: ReviewChanges? {
        if case let .ready(changes)? = shownChanges { changes } else { nil }
    }
}

private extension FakeRepository {
    /// Whether the reviewer's checkout has the commit, asked in a way that succeeds either way.
    func has(_ oid: String) async throws -> Bool {
        try await git(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"], in: checkout)
            .split(separator: "\n").contains { $0 == oid }
    }
}
