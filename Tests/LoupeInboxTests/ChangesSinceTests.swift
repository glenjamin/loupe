import Foundation
import LoupeCore
import LoupeGit
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

    @Test func theChangesSinceAHeadThePullRequestWasRebasedFromAreTheAuthorsAlone() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.conversations.review("COMMENTED", by: FakeGitHub.viewer, on: pullRequest.id, commit: first)
        // Rebased onto a base that moved on, with more changes, before the viewer opens it, so
        // the reviewed head was never in their checkout.
        try await app.moveBase(["README": "An app, documented.\n", "base.go": "package app\n"])
        try await app.repo.git(["rebase", "--quiet", "main"], in: app.repo.contributorDirectory)
        try await app.repo.commit(["app.go": "package app\n\nfunc Hello() string { return \"hi\" }\n", "notes.md": "Notes\n"], message: "Say hi")
        try await app.forcePush(pullRequest)
        let tab = try await app.open(pullRequest)
        #expect(try await !app.repo.has(first))
        let before = try await app.repo.checkoutState()

        let anchor = try #require(tab.anchors.first)
        #expect(anchor.oid == first)
        await tab.prepareAnchors()

        #expect(tab.anchorState(of: anchor) == .ready)
        #expect(try await app.repo.has(first), "fetched by oid")
        #expect(tab.diffStat(of: .since(anchor)) == DiffStat(files: 2, additions: 2, deletions: 1))
        await tab.show(.since(anchor))
        #expect(tab.shownChoice == .since(anchor))
        #expect(tab.shown?.files.map(\.path) == ["app.go", "notes.md"], "what the base gained isn't among them")
        let lines = tab.file("app.go")?.hunks.flatMap(\.lines).map(\.text)
        #expect(lines?.contains("func Hello() string { return \"hey\" }") == true, "from the reviewed version")
        #expect(lines?.contains("func Hello() string { return \"hi\" }") == true)
        #expect(tab.unseparatedPaths.isEmpty)

        #expect(try await app.repo.checkoutState() == before, "the checkout is left alone")
    }

    @Test func aFileWhoseChangesDontReplayOntoTheNewBaseShowsAllItsChangesFlagged() async throws {
        let app = try await SinceApp()
        let (pullRequest, _) = try await app.pushPullRequest()
        let reviewed = try await app.pushCommit(["README": "An app that says hey.\n"], to: pullRequest)
        try await app.conversations.review("APPROVED", by: FakeGitHub.viewer, on: pullRequest.id, commit: reviewed)
        try await app.moveBase(["README": "The app.\n", "base.go": "package app\n"])
        // The author resolves README's conflict in rebasing, and changes nothing else.
        try await app.repo.git(["switch", "--quiet", "-C", "feature", "main"], in: app.repo.contributorDirectory)
        try await app.repo.commit(["app.go": "package app\n\nfunc Hello() string { return \"hey\" }\n", "README": "The app that says hey.\n"], message: "Say hey, rebased")
        try await app.forcePush(pullRequest)
        let tab = try await app.open(pullRequest)

        let anchor = try #require(tab.anchors.first)
        await tab.prepareAnchors()
        #expect(tab.anchorState(of: anchor) == .ready)
        await tab.show(.since(anchor))

        #expect(tab.shown?.files.map(\.path) == ["README"], "app.go replays as it is now, and base.go is the base's")
        let lines = tab.file("README")?.hunks.flatMap(\.lines).map(\.text)
        #expect(lines == ["An app that says hey.", "The app that says hey."], "the whole change since, the base's part included")
        #expect(tab.unseparatedPaths == ["README"])
        await tab.show(.all)
        #expect(tab.unseparatedPaths.isEmpty, "flagged only in the changes since")

        let replayed = try app.replayedObjects()
        #expect(!replayed.isEmpty, "the trees the replay made are Loupe's own")
        for oid in replayed {
            #expect(try await !app.repo.has(oid), "and none is written into the checkout")
        }
    }

    @Test func aPushThatOnlyRebasedSaysSoAndCantBePicked() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.conversations.review("COMMENTED", by: FakeGitHub.viewer, on: pullRequest.id, commit: first)
        try await app.moveBase(["base.go": "package app\n"])
        try await app.repo.git(["rebase", "--quiet", "main"], in: app.repo.contributorDirectory)
        let rebased = try await app.forcePush(pullRequest)
        await app.conversations.forcePush(from: first, to: rebased, on: pullRequest.id)
        let tab = try await app.open(pullRequest)
        let before = try await app.repo.checkoutState()

        let anchor = try #require(tab.anchors.first)
        await tab.prepareAnchors()
        #expect(tab.anchorState(of: anchor) == .onlyRebased)
        #expect(tab.diffStat(of: .since(anchor)) == nil)
        await tab.show(.since(anchor))
        #expect(tab.shownChoice == .all)
        #expect(try await app.repo.checkoutState() == before, "the checkout is left alone")

        // Its force-push shows the same, in the picker, as there's nothing to show.
        await tab.showForcePush(from: first, to: rebased)
        let push = try #require(tab.anchors.first { $0.kind == .forcePush })
        #expect(tab.anchorState(of: push) == .onlyRebased)
        #expect(tab.shownChoice == .all)
        #expect(tab.section == .files)
        #expect(tab.isPickingCommit, "the picker says why")
    }

    @Test func aForcePushInTheConversationShowsWhatThatPushChanged() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.moveBase(["base.go": "package app\n"])
        try await app.repo.git(["rebase", "--quiet", "main"], in: app.repo.contributorDirectory)
        try await app.repo.commit(["app.go": "package app\n\nfunc Hello() string { return \"hi\" }\n"], message: "Say hi")
        let pushed = try await app.forcePush(pullRequest)
        await app.conversations.forcePush(from: first, to: pushed, on: pullRequest.id)
        // The PR has moved on since that push.
        _ = try await app.pushCommit(["notes.md": "Notes\n"], to: pullRequest)
        let tab = try await app.open(pullRequest)
        #expect(tab.section == .conversation)

        await tab.showForcePush(from: first, to: pushed)

        #expect(tab.section == .files)
        guard case let .since(anchor) = tab.shownChoice else {
            Issue.record("expected the push's changes, got \(tab.shownChoice)")
            return
        }
        #expect(anchor.kind == .forcePush)
        #expect(anchor.oid == first)
        #expect(anchor.head == pushed)
        #expect(anchor.at != nil, "when it was pushed, from the timeline")
        #expect(tab.anchors.contains(anchor), "listed in the picker while the tab is open")
        #expect(tab.shown?.files.map(\.path) == ["app.go"], "not the base's, nor the commit after it")
        #expect(tab.diffStat(of: .since(anchor)) == DiffStat(files: 1, additions: 1, deletions: 1))
        let shownApp = try #require(tab.file("app.go"))
        #expect(tab.commentableAnchors(of: shownApp) == nil, "comments are on the whole PR's diff")

        await tab.reload()
        #expect(tab.shownChoice == .all)
        #expect(tab.anchors.contains(anchor))
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
        tabs = Self.tabs(github, details, store, repo)
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

    /// Commits to the base branch, `main`, and pushes it, leaving the contributor on the PR's
    /// branch, `feature`.
    func moveBase(_ files: [String: String]) async throws {
        try await repo.switchTo("main")
        try await repo.commit(files, message: "Move the base on")
        try await repo.push()
        try await repo.switchTo("feature")
    }

    /// Force-pushes the contributor's branch as the PR's head, onto `main` as it is now, as after
    /// a rebase, and returns the head.
    @discardableResult
    func forcePush(_ pullRequest: PullRequestSummary) async throws -> String {
        try await repo.push(asPullRequest: pullRequest.number)
        let head = try await repo.git(["rev-parse", "HEAD"], in: repo.contributorDirectory)
        let base = try await repo.git(["rev-parse", "main"], in: repo.contributorDirectory)
        try await github.edit(pullRequest.id) { $0.headRefOid = head; $0.baseRefOid = base; $0.baseRefName = "main" }
        await tabs.lists.refresh()
        return head
    }

    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }

    /// Fresh models over the same store, as on the next launch.
    func relaunch() -> TabsModel {
        Self.tabs(github, details, store, repo)
    }

    /// The oids of the objects replays have written.
    func replayedObjects() throws -> [String] {
        let directory = Self.replayedObjects(of: repo)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.compactMap { file in
            let fanOut = file.deletingLastPathComponent().lastPathComponent
            return fanOut.count == 2 ? fanOut + file.lastPathComponent : nil
        }
    }

    private static func tabs(_ github: FakeGitHub, _ details: FakePullRequestDetails, _ store: PullRequestStore, _ repo: FakeRepository) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        let differ = PullRequestDiffer(replayedObjects: replayedObjects(of: repo))
        return .manuallyTimed(lists: lists, store: store, differ: differ, client: details.client(), notifications: github.notifications())
    }

    /// Beside the repo, so it goes when the repo does.
    private static func replayedObjects(of repo: FakeRepository) -> URL {
        repo.root.appending(path: "replayed-objects", directoryHint: .isDirectory)
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
