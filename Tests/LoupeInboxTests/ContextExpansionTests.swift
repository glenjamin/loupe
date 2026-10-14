import Foundation
import LoupeCore
import LoupeGit
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ContextExpansionTests {
    @Test func revealingEveryHiddenLineGivesWhatGitShowsWithTheWholeFileAsContext() async throws {
        let app = try await ExpansionApp()
        let repo = try await FakeRepository()
        let pullRequest = try await app.pushPullRequest(in: repo)
        let tab = try await app.open(pullRequest)
        let diff = try #require(tab.file("app.go"))
        #expect(diff.hunks.count == 2)

        // Its end is offered once the file has been read.
        #expect(tab.expandableContext(of: diff) == ExpandableContext())
        await tab.readContext(of: diff)
        #expect(tab.expandableContext(of: diff) == ExpandableContext(newLineCount: 61))

        await tab.expandContext(of: diff, ContextExpansion(hunk: 1, direction: .above))
        #expect(tab.expandedFile(diff).hunks.count == 2)
        await tab.expandContext(of: diff, ContextExpansion(hunk: 0, direction: .below))
        #expect(tab.expandedFile(diff).hunks.count == 1, "the last of the gap closes it")
        await tab.expandContext(of: diff, ContextExpansion(hunk: 0, direction: .above))
        await tab.expandContext(of: diff, ContextExpansion(hunk: 0, direction: .below, lines: nil))

        let whole = try await repo.git(["diff", "-U1000", pullRequest.baseRefOid ?? "", pullRequest.headRefOid ?? "", "--", "app.go"], in: repo.checkout)
        let expected = try #require(Diff(parsing: whole + "\n").files.first)
        let shown = tab.expandedFile(diff)
        #expect(shown.hunks.map(\.header) == expected.hunks.map(\.header))
        #expect(shown.hunks.map(\.lines) == expected.hunks.map(\.lines))
    }

    @Test func whatsRevealedIsKeptPerFileAndRangeUntilTheDiffIsProducedAgain() async throws {
        let app = try await ExpansionApp()
        let repo = try await FakeRepository()
        let pullRequest = try await app.pushPullRequest(in: repo)
        let tab = try await app.open(pullRequest)
        let diff = try #require(tab.file("app.go"))
        let added = try #require(tab.file("new.go"))
        #expect(tab.expandableContext(of: added) == nil, "an added file is shown whole")

        await tab.expandContext(of: diff, ContextExpansion(hunk: 0, direction: .above))
        #expect(tab.expandedFile(diff).hunks[0].newStart == 1)

        tab.selectedFile = added.id
        tab.selectedFile = diff.id
        #expect(tab.expandedFile(diff).hunks[0].newStart == 1, "kept while looking at another file")

        // A commit's own changes are a different range, so nothing is revealed there yet.
        let commit = try #require(tab.ready?.commits.first)
        await tab.showCommit(commit.oid)
        let inCommit = try #require(tab.file("app.go"))
        #expect(tab.expandedFile(inCommit).hunks[0].newStart == 7)
        await tab.showCommit(nil)
        #expect(tab.expandedFile(diff).hunks[0].newStart == 1)

        await tab.reload()
        #expect(tab.expandedFile(try #require(tab.file("app.go"))).hunks[0].newStart == 7)
    }
}

/// The app's models over the PR fixture and an in-memory store.
@MainActor
private struct ExpansionApp {
    let github: FakeGitHub
    let details = FakePullRequestDetails()
    let store: PullRequestStore
    let tabs: TabsModel

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        tabs = TabsModel(lists: lists, store: store, client: details.client(), notifications: github.notifications())
        await tabs.lists.refresh()
    }

    /// Makes the first to-review PR change a 60-line `app.go` in two places far apart, three
    /// lines for one near the top and one line removed near the end, then add `new.go`.
    func pushPullRequest(in repo: FakeRepository) async throws -> PullRequestSummary {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let lines = (1...60).map { "\($0) line" }
        let branchPoint = try await repo.commit(["app.go": lines.joined(separator: "\n") + "\n"], message: "Start")
        try await repo.push()
        try await repo.switchTo("feature", creatingFrom: "main")
        var changed = lines
        changed.remove(at: 49)
        changed.replaceSubrange(9...9, with: ["10a", "10b", "10c"])
        try await repo.commit(["app.go": changed.joined(separator: "\n") + "\n"], message: "Change app.go")
        let head = try await repo.commit(["new.go": "package app\n"], message: "Add new.go")
        try await repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = head; $0.baseRefOid = branchPoint }
        await tabs.lists.refresh()
        return try #require(tabs.lists.pullRequest(id: listed.id))
    }

    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }
}

private extension PullRequestTab {
    func file(_ path: String) -> FileDiff? {
        guard case let .ready(changes)? = shownChanges else { return nil }
        return changes.files.first { $0.path == path }
    }

    var ready: ReviewDiff? {
        if case let .ready(diff) = phase { diff } else { nil }
    }
}
