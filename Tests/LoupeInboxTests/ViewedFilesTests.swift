@testable import LoupeFakeGitHub
import Foundation
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ViewedFilesTests {
    @Test func openingAPullRequestTakesItsViewedFilesFromGitHubPagingPastVendoredOnes() async throws {
        let app = try await ViewedApp()
        let pullRequest = app.toReview[0]
        let vendored = (1...150).map { "vendor/lib/\($0).go" }
        await app.viewed.add(pullRequest.id, files: vendored.map { ($0, .viewed) } + [("app.go", .viewed), ("README", .dismissed), ("main.go", .unviewed)])

        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()

        #expect(await app.viewed.pagesServed == 2, "GitHub lists vendored files too, so the real ones can be on a later page")
        #expect(tab.viewedState(of: "app.go") == .viewed)
        #expect(tab.viewedState(of: "README") == .dismissed)
        #expect(tab.viewedState(of: "main.go") == .unviewed)
        #expect(tab.viewedState(of: "not/in/the/pr") == .unviewed)
        let stored = try app.store.viewedStates(of: pullRequest.id)
        #expect(stored.count == 153)
        #expect(stored["app.go"] == .viewed)

        // Next launch shows what was stored before GitHub answers, or if it can't.
        await app.viewed.fail()
        let nextRun = try #require(app.relaunch().tab(id: pullRequest.id))
        #expect(nextRun.viewedState(of: "app.go") == .viewed)
        await nextRun.load()
        #expect(nextRun.viewedState(of: "README") == .dismissed)
    }

    @Test func markingAFileViewedShowsAtOnceAndTellsGitHub() async throws {
        let app = try await ViewedApp()
        let pullRequest = app.toReview[0]
        await app.viewed.add(pullRequest.id, files: [("app.go", .unviewed), ("README", .unviewed)])
        let tab = try await app.open(pullRequest)

        await app.viewed.hold()
        let marking = Task { await tab.setViewed(true, path: "app.go") }
        await app.viewed.waitForHeldRequest()
        #expect(tab.viewedState(of: "app.go") == .viewed, "shown before GitHub answers")
        #expect(await app.viewed.state(of: "app.go", in: pullRequest.id) == .unviewed)

        await app.viewed.release()
        await marking.value
        #expect(await app.viewed.state(of: "app.go", in: pullRequest.id) == .viewed)
        #expect(try app.store.viewedStates(of: pullRequest.id)["app.go"] == .viewed)
        #expect(tab.viewedStateError == nil)

        await tab.toggleViewed(path: "app.go")
        #expect(tab.viewedState(of: "app.go") == .unviewed)
        #expect(await app.viewed.state(of: "app.go", in: pullRequest.id) == .unviewed)
        #expect(await app.viewed.mutations == [.mark("app.go"), .unmark("app.go")])
    }

    @Test func aChangeGitHubRefusesIsPutBack() async throws {
        let app = try await ViewedApp()
        let pullRequest = app.toReview[0]
        await app.viewed.add(pullRequest.id, files: [("app.go", .dismissed)])
        let tab = try await app.open(pullRequest)

        await app.viewed.fail()
        await tab.setViewed(true, path: "app.go")
        #expect(tab.viewedState(of: "app.go") == .dismissed)
        #expect(try #require(tab.viewedStateError).contains("app.go"))
        #expect(try app.store.viewedStates(of: pullRequest.id)["app.go"] == .dismissed)

        // GitHub refuses a path that isn't part of the PR, as when the diff is older than GitHub's.
        await app.viewed.recover()
        await tab.setViewed(true, path: "gone.go")
        #expect(tab.viewedState(of: "gone.go") == .unviewed)
        #expect(try #require(tab.viewedStateError).contains("Filepath must be part of pull request"))

        await tab.setViewed(true, path: "app.go")
        #expect(tab.viewedState(of: "app.go") == .viewed)
        #expect(tab.viewedStateError == nil, "cleared once a change goes through")
    }

    @Test func markingViewedAndAdvancingSkipsViewedFilesWrapsAndStopsWhenAllAreViewed() async throws {
        let repo = try await FakeRepository()
        let app = try await ViewedApp()
        let files = ["a.txt", "b.txt", "c.txt", "d.txt"]
        let pullRequest = try await app.pushPullRequest(changing: files, in: repo)
        await app.viewed.add(pullRequest.id, files: [("a.txt", .unviewed), ("b.txt", .viewed), ("c.txt", .dismissed), ("d.txt", .unviewed)])
        let tab = try await app.open(pullRequest)
        guard case let .ready(review) = tab.phase else { Issue.record("expected a diff, got \(tab.phase)"); return }
        #expect(review.changes.files.map(\.path) == files)
        #expect(tab.selectedFile == "a.txt")

        tab.selectedFile = "d.txt"
        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "a.txt", "wraps to the first not viewed")
        #expect(tab.viewedState(of: "d.txt") == .viewed)

        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "c.txt", "a file changed since it was viewed needs another look")
        #expect(!tab.allFilesViewed)

        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "c.txt", "none left, so it stays")
        #expect(tab.allFilesViewed)

        await tab.toggleViewed(path: "c.txt")
        #expect(tab.selectedFile == "c.txt", "unmarking stays on the file")
        #expect(!tab.allFilesViewed)
        #expect(await app.viewed.mutations == [.mark("d.txt"), .mark("a.txt"), .mark("c.txt"), .unmark("c.txt")])
    }

    @Test func movingOnFollowsTheFileListsTreeWithDirectoriesBeforeFiles() async throws {
        let repo = try await FakeRepository()
        let app = try await ViewedApp()
        let pullRequest = try await app.pushPullRequest(changing: ["a.txt", "lib/b.txt", "lib/sub/c.txt"], in: repo)
        await app.viewed.add(pullRequest.id, files: [("a.txt", .unviewed), ("lib/b.txt", .unviewed), ("lib/sub/c.txt", .unviewed)])
        let tab = try await app.open(pullRequest)
        #expect(tab.selectedFile == "lib/sub/c.txt", "opens on the first file the list shows")

        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "lib/b.txt")
        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "a.txt")
    }

    @Test func movingOnPassesOverHiddenFilesWhichCanStillBeMarkedReviewed() async throws {
        let repo = try await FakeRepository()
        let app = try await ViewedApp()
        let pullRequest = try await app.pushPullRequest(changing: ["a.txt", "b.txt", "go.sum", "vendor/lib/lib.go"], in: repo)
        await app.viewed.add(pullRequest.id, files: [("a.txt", .unviewed), ("b.txt", .unviewed), ("go.sum", .unviewed), ("vendor/lib/lib.go", .unviewed)])
        let tab = try await app.open(pullRequest)

        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "b.txt")
        await tab.markViewedAndAdvance()
        #expect(tab.selectedFile == "b.txt", "none left to review but hidden ones")
        #expect(tab.allFilesViewed)

        tab.selectedFile = "go.sum"
        await tab.toggleViewed(path: "go.sum")
        #expect(tab.viewedState(of: "go.sum") == .viewed)
        #expect(await app.viewed.state(of: "go.sum", in: pullRequest.id) == .viewed)
    }

    @Test func onceACommitsFilesAreReviewedMovingOnShowsTheNextCommitsFirstUnreviewedFile() async throws {
        let repo = try await FakeRepository()
        let app = try await ViewedApp()
        let (pullRequest, commits) = try await app.pushPullRequest(commits: [["a.txt", "b.txt"], ["c.txt", "d.txt"], ["e.txt", "f.txt"]], in: repo)
        await app.viewed.add(pullRequest.id, files: [("a.txt", .unviewed), ("b.txt", .viewed), ("c.txt", .viewed), ("d.txt", .unviewed), ("e.txt", .viewed), ("f.txt", .viewed)])
        let tab = try await app.open(pullRequest)
        await tab.show(.commit(commits[0]))
        #expect(tab.selectedFile == "a.txt")
        #expect(tab.nextCommit?.oid == commits[1])

        await tab.markViewedAndAdvance()
        #expect(tab.shownChoice == .commit(commits[1]), "the commit's last file to review was marked")
        #expect(tab.shown?.files.map(\.path) == ["c.txt", "d.txt"])
        #expect(tab.selectedFile == "d.txt", "c.txt is already reviewed")
        #expect(tab.viewedState(of: "a.txt") == .viewed)

        await tab.markViewedAndAdvance()
        #expect(tab.shownChoice == .commit(commits[2]))
        #expect(tab.selectedFile == "e.txt", "all reviewed, so its first file")
        #expect(tab.nextCommit == nil, "it's the last commit")
        #expect(await app.viewed.mutations == [.mark("a.txt"), .mark("d.txt")])
    }

    @Test func onTheLastCommitOrTheWholePRMovingOnStaysWithNoFileLeftToReview() async throws {
        let repo = try await FakeRepository()
        let app = try await ViewedApp()
        let (pullRequest, commits) = try await app.pushPullRequest(commits: [["a.txt"], ["b.txt", "c.txt"]], in: repo)
        await app.viewed.add(pullRequest.id, files: [("a.txt", .unviewed), ("b.txt", .viewed), ("c.txt", .unviewed)])
        let tab = try await app.open(pullRequest)
        await tab.show(.commit(commits[1]))
        tab.selectedFile = "c.txt"

        await tab.markViewedAndAdvance()
        #expect(tab.shownChoice == .commit(commits[1]))
        #expect(tab.selectedFile == "c.txt")
        await tab.markViewedAndAdvance()
        #expect(tab.shownChoice == .commit(commits[1]), "there's no commit after the last")
        #expect(tab.selectedFile == "c.txt")

        await tab.show(.all)
        tab.selectedFile = "a.txt"
        await tab.markViewedAndAdvance()
        #expect(tab.shownChoice == .all, "the whole PR's changes have no next commit")
        #expect(tab.nextCommit == nil)
        #expect(tab.selectedFile == "a.txt")
        #expect(tab.allFilesViewed)
    }

    @Test func markingACommitsLastFileReviewedMovesPastItInTheNextCommit() async throws {
        let repo = try await FakeRepository()
        let app = try await ViewedApp()
        let (pullRequest, commits) = try await app.pushPullRequest(commits: [["a.txt"], ["a.txt", "b.txt"]], in: repo)
        await app.viewed.add(pullRequest.id, files: [("a.txt", .unviewed), ("b.txt", .unviewed)])
        let tab = try await app.open(pullRequest)
        await tab.show(.commit(commits[0]))

        await tab.markViewedAndAdvance()
        #expect(tab.shownChoice == .commit(commits[1]))
        #expect(tab.selectedFile == "b.txt", "a.txt was just marked reviewed, though the next commit changes it too")
        #expect(tab.viewedState(of: "a.txt") == .viewed)
        #expect(await app.viewed.state(of: "a.txt", in: pullRequest.id) == .viewed)
    }

    @Test func reloadingTakesViewedFilesFromGitHubAgain() async throws {
        let app = try await ViewedApp()
        let pullRequest = app.toReview[0]
        await app.viewed.add(pullRequest.id, files: [("app.go", .viewed)])
        let tab = try await app.open(pullRequest)

        // As when a push changes a viewed file.
        try await app.viewed.change("app.go", in: pullRequest.id, to: .dismissed)
        await tab.reload()

        #expect(tab.viewedState(of: "app.go") == .dismissed)
        #expect(try app.store.viewedStates(of: pullRequest.id)["app.go"] == .dismissed)
    }
}

/// The app's models over the PR fixture and an in-memory store, with viewed files kept by
/// `FakeViewedFiles`.
@MainActor
private struct ViewedApp {
    let github: FakeGitHub
    let viewed = FakeViewedFiles()
    let store: PullRequestStore
    let tabs: TabsModel

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        tabs = Self.tabs(github, viewed, store)
        await tabs.lists.refresh()
    }

    var toReview: [PullRequestSummary] {
        tabs.lists.pullRequests(in: .toReview)
    }

    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }

    /// Makes the first to-review PR one commit changing `paths` in `repo`, and returns it as
    /// the lists now have it.
    func pushPullRequest(changing paths: [String], in repo: FakeRepository) async throws -> PullRequestSummary {
        try await pushPullRequest(commits: [paths], in: repo).pullRequest
    }

    /// Makes the first to-review PR a commit for each list of paths in `repo`, each changing
    /// its paths, and returns it as the lists now have it with its commits' oids.
    func pushPullRequest(commits: [[String]], in repo: FakeRepository) async throws -> (pullRequest: PullRequestSummary, commits: [String]) {
        let listed = toReview[0]
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try await repo.switchTo("feature", creatingFrom: "main")
        var oids: [String] = []
        for (index, paths) in commits.enumerated() {
            let files = Dictionary(uniqueKeysWithValues: paths.map { ($0, "\($0) as of commit \(index + 1)\n") })
            oids.append(try await repo.commit(files, message: "Change files, part \(index + 1)"))
        }
        let head = try #require(oids.last)
        try await repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = head; $0.baseRefOid = branchPoint }
        await tabs.lists.refresh()
        return (try #require(tabs.lists.pullRequest(id: listed.id)), oids)
    }

    /// Fresh models over the same store, as on the next launch.
    func relaunch() throws -> TabsModel {
        Self.tabs(github, viewed, store)
    }

    private static func tabs(_ github: FakeGitHub, _ viewed: FakeViewedFiles, _ store: PullRequestStore) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        return .manuallyTimed(lists: lists, store: store, client: FakePullRequestDetails(viewed: viewed).client(), notifications: github.notifications())
    }
}

private extension PullRequestTab {
    var shown: ReviewChanges? {
        guard case let .ready(changes)? = shownChanges else { return nil }
        return changes
    }
}
