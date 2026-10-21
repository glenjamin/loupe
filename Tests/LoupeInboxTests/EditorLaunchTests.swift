@testable import LoupeFakeGitHub
import Foundation
import LoupeGit
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct EditorLaunchTests {
    @Test func opensTheCheckoutInItsEditorOnThePullRequestsBranch() async throws {
        let app = try await EditorApp()
        let repo = try await FakeRepository()
        try await repo.commit(["go.mod": "module github.com/tamarinworks/app\n"], message: "Make it a module")
        try await repo.push()
        try await repo.git(["pull", "--quiet", "--ff-only"], in: repo.checkout)
        let (pullRequest, head) = try await app.pushPullRequest(in: repo)
        let tab = try await app.open(pullRequest)
        #expect(tab.editor == .goLand)
        #expect(tab.editorCheckout == repo.checkout)

        var opened: [(Editor, URL)] = []
        await tab.openInEditor { opened.append(($0, $1)) }

        #expect(opened.map(\.0) == [.goLand])
        #expect(opened.map(\.1) == [repo.checkout])
        #expect(tab.editorLaunch.report == nil, "the editor coming up is all the feedback needed")
        #expect(!tab.editorLaunch.isSwitching)
        #expect(try await repo.git(["branch", "--show-current"], in: repo.checkout) == pullRequest.headRefName)
        #expect(try await repo.git(["rev-parse", "HEAD"], in: repo.checkout) == head)
    }

    @Test func aCheckoutWithUncommittedChangesIsLeftAloneAndTheEditorNotOpened() async throws {
        let app = try await EditorApp()
        let repo = try await FakeRepository()
        let (pullRequest, _) = try await app.pushPullRequest(in: repo)
        let tab = try await app.open(pullRequest)
        try "changed\n".write(to: repo.checkout.appending(path: "README"), atomically: true, encoding: .utf8)
        let before = try await repo.checkoutState()

        var opened = 0
        await tab.openInEditor { _, _ in opened += 1 }

        #expect(opened == 0)
        let report = try #require(tab.editorLaunch.report)
        #expect(report.isFailure)
        #expect(report.message.contains(repo.checkout.path(percentEncoded: false)))
        #expect(report.message.contains("uncommitted changes"))
        #expect(try await repo.checkoutState() == before)
    }

    @Test func anEditorThatWontOpenIsReportedWithTheBranchLeftCheckedOut() async throws {
        let app = try await EditorApp()
        let repo = try await FakeRepository()
        let (pullRequest, _) = try await app.pushPullRequest(in: repo)
        let tab = try await app.open(pullRequest)
        #expect(tab.editor == .visualStudioCode)

        await tab.openInEditor { _, _ in throw NotInstalled() }

        let report = try #require(tab.editorLaunch.report)
        #expect(report.title == "Couldn't open VS Code")
        #expect(report.message.contains("isn't installed"))
        #expect(try await repo.git(["branch", "--show-current"], in: repo.checkout) == pullRequest.headRefName)
    }

    @Test func aForksPullRequestSaysItsBranchIsLocalOnly() async throws {
        let app = try await EditorApp()
        let repo = try await FakeRepository()
        let (pullRequest, _) = try await app.pushPullRequest(in: repo)
        try await repo.git(["push", "--quiet", "origin", "--delete", pullRequest.headRefName], in: repo.contributorDirectory)
        let tab = try await app.open(pullRequest)

        var opened = 0
        await tab.openInEditor { _, _ in opened += 1 }

        #expect(opened == 1)
        let report = try #require(tab.editorLaunch.report)
        #expect(!report.isFailure)
        #expect(report.message.contains("fork"))
        #expect(try await repo.git(["branch", "--show-current"], in: repo.checkout) == "pr-\(pullRequest.number)")
    }
}

private struct NotInstalled: Error, LocalizedError {
    var errorDescription: String? { "it isn't installed." }
}

/// The app's models over the PR fixture and an in-memory store.
@MainActor
private struct EditorApp {
    let github: FakeGitHub
    let store: PullRequestStore
    let tabs: TabsModel

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        tabs = TabsModel.manuallyTimed(lists: lists, store: store, client: FakePullRequestDetails().client(), notifications: github.notifications())
        await tabs.lists.refresh()
    }

    /// Makes the first to-review PR a commit on a branch named as the PR's head in `repo`, and
    /// returns it as the lists now have it, with its head commit.
    func pushPullRequest(in repo: FakeRepository) async throws -> (PullRequestSummary, String) {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try await repo.switchTo(listed.headRefName, creatingFrom: "main")
        let head = try await repo.commit(["app.go": "package app // changed\n"], message: "Change the app")
        try await repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = head; $0.baseRefOid = branchPoint }
        await tabs.lists.refresh()
        return (try #require(tabs.lists.pullRequest(id: listed.id)), head)
    }

    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }
}
