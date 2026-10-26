@testable import LoupeFakeGitHub
import Foundation
import LoupeInbox
import LoupeModel
import Testing

@MainActor
struct ConflictsTests {
    @Test func aConflictingPullRequestsFilesAreFoundAsItOpensByMergingItIntoItsBaseAsFetched() async throws {
        let app = try await SinceApp()
        let (pullRequest, _) = try await app.pushPullRequest()
        // The PR also deletes go.sum, a hidden file, which the base changes too.
        try await app.repo.commit(["go.sum": nil, "notes.md": "Notes\n"], message: "Drop go.sum")
        try await app.repo.push(asPullRequest: pullRequest.number)
        let head = try await app.repo.git(["rev-parse", "HEAD"], in: app.repo.contributorDirectory)
        try await app.moveBase(["app.go": "package app\n\nfunc Hello() string { return \"hiya\" }\n", "go.sum": "example.com/lib v1.1.0 h1:def\n", "README": "The app.\n"])
        try await app.conflict(pullRequest, head: head)
        let before = try await app.repo.checkoutState()
        let tab = try await app.open(pullRequest)

        #expect(tab.pullRequest.mergeable == .conflicting)
        #expect(tab.conflictedFiles == .found(["app.go", "go.sum"]), "not README, which only the base changed, nor notes.md, only the PR's")
        #expect(try await app.repo.checkoutState() == before, "the checkout is left alone")
        let made = try app.replayedObjects()
        #expect(!made.isEmpty, "the merge's trees are Loupe's own")
        for oid in made {
            #expect(try await !app.repo.has(oid), "and none is written into the checkout")
        }

        // Each can be shown among the whole PR's changes, from whatever was shown.
        let commit = try #require(tab.ready?.commits.last)
        await tab.show(.commit(commit.oid))
        #expect(tab.isChanged("go.sum"))
        await tab.showChangedFile("go.sum")
        #expect(tab.section == .files)
        #expect(tab.shownChoice == .all)
        #expect(tab.selectedFile == "go.sum")
        await tab.showChangedFile("README")
        #expect(tab.selectedFile == "go.sum", "README isn't among the PR's changes")
    }

    @Test func aPullRequestThatMergesCleanlyIntoItsBaseAsFetchedHasNoConflictingFiles() async throws {
        let app = try await SinceApp()
        let (pullRequest, head) = try await app.pushPullRequest()
        // GitHub's verdict came from a newer base than the one fetched, which the PR merges into.
        try await app.moveBase(["README": "The app.\n"])
        try await app.conflict(pullRequest, head: head)
        let tab = try await app.open(pullRequest)

        #expect(tab.conflictedFiles == .found([]))
    }

    @Test func aPullRequestGitHubDoesntSayConflictsIsntLookedAtUntilAsked() async throws {
        let app = try await SinceApp()
        let (pullRequest, _) = try await app.pushPullRequest()
        try await app.moveBase(["app.go": "package app\n\nfunc Hello() string { return \"hiya\" }\n"])
        // GitHub has yet to work out whether it merges into the new base.
        _ = try await app.forcePush(pullRequest)
        let tab = try await app.open(pullRequest)
        #expect(tab.pullRequest.mergeable != .conflicting)
        #expect(tab.conflictedFiles == nil)

        await tab.findConflicts()

        #expect(tab.conflictedFiles == .found(["app.go"]))
    }

    @Test func theConflictingFilesFollowANewHeadOnReload() async throws {
        let app = try await SinceApp()
        let (pullRequest, first) = try await app.pushPullRequest()
        try await app.moveBase(["app.go": "package app\n\nfunc Hello() string { return \"hiya\" }\n"])
        try await app.conflict(pullRequest, head: first)
        let tab = try await app.open(pullRequest)
        #expect(tab.conflictedFiles == .found(["app.go"]))

        // The author resolves it by merging the base in, before GitHub has checked again.
        try await app.repo.git(["merge", "--quiet", "--no-edit", "-X", "theirs", "main"], in: app.repo.contributorDirectory)
        try await app.forcePush(pullRequest)
        await tab.reload()
        #expect(tab.conflictedFiles == .found([]), "the new head is looked at afresh")
    }

    @Test func withoutACheckoutTheConflictingFilesCantBeFound() async throws {
        let app = try await SinceApp()
        let pullRequest = try #require(app.tabs.lists.pullRequests(in: .toReview).first)
        let tab = try await app.open(pullRequest)

        await tab.findConflicts()

        guard case let .unavailable(reason)? = tab.conflictedFiles else {
            Issue.record("expected no checkout to look in, got \(String(describing: tab.conflictedFiles))")
            return
        }
        #expect(reason.contains("no local checkout"))
    }
}

private extension SinceApp {
    /// Has GitHub say the PR at `head` conflicts with `main` as it is now, which it bases it on.
    func conflict(_ pullRequest: PullRequestSummary, head: String) async throws {
        let base = try await repo.git(["rev-parse", "main"], in: repo.contributorDirectory)
        try await github.edit(pullRequest.id) { $0.headRefOid = head; $0.baseRefOid = base; $0.baseRefName = "main" }
        try await github.setMergeState(of: pullRequest.id, "DIRTY", mergeable: "CONFLICTING")
        await tabs.lists.refresh()
    }
}
