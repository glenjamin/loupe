import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct PackageLockTests {
    @Test func aBumpedPackageLockShowsItsPackageChangesOnceShown() async throws {
        let app = try await PackageLockApp()
        let repo = try await FakeRepository()
        let pullRequest = try await app.pushPullRequest(in: repo, startingWith: [
            "package-lock.json": lockfile(["fizzle": "2.0.0", "old-widget": "0.3.1"]),
        ], changing: [
            "package-lock.json": lockfile(["fizzle": "2.1.0", "@acme/bolts": "0.0.9"]),
            "app.go": "package app // changed\n",
        ])
        let tab = try await app.open(pullRequest)
        #expect(tab.shown?.hidden.map(\.path) == ["package-lock.json"], "a lockfile stays hidden")
        #expect(tab.packageLockChanges(of: "package-lock.json") == nil, "compared only once shown")

        await tab.comparePackageLock("package-lock.json")

        #expect(tab.packageLockChanges(of: "package-lock.json")?.changes == [
            .added(key: "node_modules/@acme/bolts", version: "0.0.9"),
            .updated(key: "node_modules/fizzle", from: "2.0.0", to: "2.1.0"),
            .removed(key: "node_modules/old-widget", version: "0.3.1"),
        ], "integrity isn't compared")
        #expect(!tab.showsRawDiff(of: "package-lock.json"))
        tab.setShowsRawDiff(true, path: "package-lock.json")
        #expect(tab.showsRawDiff(of: "package-lock.json"))
    }

    @Test func anAddedPackageLockIsAllAdditions() async throws {
        let app = try await PackageLockApp()
        let repo = try await FakeRepository()
        let pullRequest = try await app.pushPullRequest(in: repo, changing: [
            "web/package-lock.json": lockfile(["fizzle": "2.0.0", "sprocket": "1.4.0"]),
        ])
        let tab = try await app.open(pullRequest)

        await tab.comparePackageLock("web/package-lock.json")

        #expect(tab.packageLockChanges(of: "web/package-lock.json")?.changes == [
            .added(key: "node_modules/fizzle", version: "2.0.0"),
            .added(key: "node_modules/sprocket", version: "1.4.0"),
        ])
    }

    @Test func aPackageLockThatWontParseSaysWhy() async throws {
        let app = try await PackageLockApp()
        let repo = try await FakeRepository()
        let pullRequest = try await app.pushPullRequest(in: repo, startingWith: [
            "package-lock.json": lockfile(["fizzle": "2.0.0"]),
        ], changing: [
            "package-lock.json": "<<<<<<< HEAD\n",
        ])
        let tab = try await app.open(pullRequest)

        await tab.comparePackageLock("package-lock.json")

        #expect(tab.packageLockChanges(of: "package-lock.json")?.failure == PackageLockError.notJSON.localizedDescription)
    }
}

@MainActor
private struct PackageLockApp {
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

    /// Makes the first to-review PR a commit writing `files` in `repo`, branched from a commit on
    /// main writing `base`, and returns it as the lists now have it.
    func pushPullRequest(in repo: FakeRepository, startingWith base: [String: String?] = [:], changing files: [String: String?]) async throws -> PullRequestSummary {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = base.isEmpty ? try await repo.git(["rev-parse", "HEAD"], in: repo.checkout) : try await repo.commit(base, message: "Start")
        try await repo.push()
        try await repo.switchTo("feature", creatingFrom: "main")
        let head = try await repo.commit(files, message: "Change files")
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

/// A lockfile v3 installing each package at the top of `node_modules`.
private func lockfile(_ versions: [String: String]) -> String {
    let packages = versions.sorted { $0.key < $1.key }
        .map { #""node_modules/\#($0.key)": { "version": "\#($0.value)", "integrity": "sha512-made-up" }"# }
    return """
    {
      "name": "demo-app",
      "lockfileVersion": 3,
      "packages": {
        "": { "name": "demo-app", "version": "1.0.0" },
        \(packages.joined(separator: ",\n    "))
      }
    }

    """
}

private extension PullRequestTab {
    var shown: ReviewChanges? {
        guard case let .ready(changes)? = shownChanges else { return nil }
        return changes
    }
}

private extension DiffState<PackageLockChanges> {
    /// The changes once compared.
    var changes: [PackageLockChange]? {
        guard case let .ready(compared) = self else { return nil }
        return compared.changes
    }

    /// Why comparing failed, if it did.
    var failure: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}
