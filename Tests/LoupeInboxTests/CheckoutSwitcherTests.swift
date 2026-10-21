@testable import LoupeFakeGitHub
import Foundation
@testable import LoupeGit
import Testing

struct CheckoutSwitcherTests {
    @Test func aPullRequestsBranchIsCheckedOutAsALocalBranchTrackingTheRemote() async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("feature", creatingFrom: "main")
        let head = try await repo.commit(["app.go": "package app // feature\n"], message: "Add the feature")
        try await repo.push(asPullRequest: 7)

        let switched = try await CheckoutSwitcher().switchTo(pullRequest: 7, of: "tamarinworks/app", headRefName: "feature", in: repo.checkout)

        #expect(switched == SwitchedBranch(name: "feature", isFork: false, remote: "origin", isAtPullRequestHead: true))
        #expect(try await repo.git(["branch", "--show-current"], in: repo.checkout) == "feature")
        #expect(try await repo.git(["rev-parse", "HEAD"], in: repo.checkout) == head)
        #expect(try await repo.git(["rev-parse", "--abbrev-ref", "feature@{upstream}"], in: repo.checkout) == "origin/feature")
        #expect(try await repo.git(["status", "--porcelain"], in: repo.checkout) == "")
    }

    @Test func anExistingBranchIsFastForwardedToThePullRequestAndLoupesRefsAreLeftAlone() async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("feature", creatingFrom: "main")
        try await repo.commit(["app.go": "package app // first\n"], message: "First")
        try await repo.push(asPullRequest: 7)
        let switcher = CheckoutSwitcher()
        _ = try await switcher.switchTo(pullRequest: 7, of: "tamarinworks/app", headRefName: "feature", in: repo.checkout)
        try await repo.git(["switch", "--quiet", "main"], in: repo.checkout)
        let diffed = try await PullRequestDiffer().fetch(number: 7, of: "tamarinworks/app", baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        let head = try await repo.commit(["app.go": "package app // second\n"], message: "Second")
        try await repo.push(asPullRequest: 7)

        let switched = try await switcher.switchTo(pullRequest: 7, of: "tamarinworks/app", headRefName: "feature", in: repo.checkout)

        #expect(switched.isAtPullRequestHead)
        #expect(try await repo.git(["branch", "--show-current"], in: repo.checkout) == "feature")
        #expect(try await repo.git(["rev-parse", "HEAD"], in: repo.checkout) == head)
        // A fast-forward, despite any `merge.ff=false` in the user's config.
        #expect(try await repo.git(["rev-list", "--count", "--merges", "main..HEAD"], in: repo.checkout) == "0")
        #expect(try await repo.git(["rev-parse", "refs/loupe/pull/7/head"], in: repo.checkout) == diffed.headOid)
    }

    @Test func anExistingBranchWithCommitsOfItsOwnIsLeftAsItWas() async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("feature", creatingFrom: "main")
        try await repo.commit(["app.go": "package app // first\n"], message: "First")
        try await repo.push(asPullRequest: 7)
        let switcher = CheckoutSwitcher()
        _ = try await switcher.switchTo(pullRequest: 7, of: "tamarinworks/app", headRefName: "feature", in: repo.checkout)
        try "local\n".write(to: repo.checkout.appending(path: "local.txt"), atomically: true, encoding: .utf8)
        try await repo.git(["add", "local.txt"], in: repo.checkout)
        try await repo.git(["commit", "--quiet", "-m", "Local work"], in: repo.checkout)
        let local = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try await repo.commit(["app.go": "package app // second\n"], message: "Second")
        try await repo.push(asPullRequest: 7)

        let switched = try await switcher.switchTo(pullRequest: 7, of: "tamarinworks/app", headRefName: "feature", in: repo.checkout)

        #expect(switched == SwitchedBranch(name: "feature", isFork: false, remote: "origin", isAtPullRequestHead: false))
        #expect(try await repo.git(["rev-parse", "HEAD"], in: repo.checkout) == local)
    }

    @Test(arguments: [DirtyCase.untracked, .modified, .staged, .merging])
    func aCheckoutWithWorkUnderWayIsRefusedAndLeftUntouched(_ dirty: DirtyCase) async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("feature", creatingFrom: "main")
        try await repo.commit(["app.go": "package app // feature\n"], message: "Add the feature")
        try await repo.push(asPullRequest: 7)
        switch dirty {
        case .untracked:
            try "scratch\n".write(to: repo.checkout.appending(path: "scratch.txt"), atomically: true, encoding: .utf8)
        case .modified, .staged:
            try "changed\n".write(to: repo.checkout.appending(path: "README"), atomically: true, encoding: .utf8)
            if dirty == .staged { try await repo.git(["add", "README"], in: repo.checkout) }
        case .merging:
            let head = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
            try "\(head)\n".write(to: repo.checkout.appending(path: ".git/MERGE_HEAD"), atomically: true, encoding: .utf8)
        }
        let before = try await repo.checkoutState()

        let error = try await #require(throws: CheckoutSwitchError.self) {
            try await CheckoutSwitcher().switchTo(pullRequest: 7, of: "tamarinworks/app", headRefName: "feature", in: repo.checkout)
        }

        #expect(error == (dirty == .merging ? .operationInProgress("merge", checkout: repo.checkout) : .uncommittedChanges(checkout: repo.checkout)))
        #expect(error.localizedDescription.contains(repo.checkout.path(percentEncoded: false)))
        #expect(try await repo.checkoutState() == before)
        #expect(try await repo.git(["for-each-ref", "refs/remotes/origin/feature", "refs/heads/feature"], in: repo.checkout) == "", "nothing fetched or created")
    }

    @Test func aForksPullRequestIsCheckedOutAsALocalBranchNamedForIt() async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("fork-change", creatingFrom: "main")
        let head = try await repo.commit(["fork.go": "package app // fork\n"], message: "Change the fork")
        try await repo.push(asPullRequest: 9)
        // Only the PR's ref is on the repo's remote, as for a fork.
        try await repo.git(["push", "--quiet", "origin", "--delete", "fork-change"], in: repo.contributorDirectory)

        let switched = try await CheckoutSwitcher().switchTo(pullRequest: 9, of: "tamarinworks/app", headRefName: "fork-change", in: repo.checkout)

        #expect(switched == SwitchedBranch(name: "pr-9", isFork: true, remote: "origin", isAtPullRequestHead: true))
        #expect(try await repo.git(["branch", "--show-current"], in: repo.checkout) == "pr-9")
        #expect(try await repo.git(["rev-parse", "HEAD"], in: repo.checkout) == head)
        #expect(try await repo.git(["for-each-ref", "--format=%(upstream)", "refs/heads/pr-9"], in: repo.checkout) == "")
        #expect(try await repo.git(["for-each-ref", "refs/loupe"], in: repo.checkout) == "")
    }

    @Test func aForkBranchNamedLikeOneOfTheReposIsntMistakenForIt() async throws {
        let repo = try await FakeRepository()
        let main = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try await repo.switchTo("fork-main", creatingFrom: "main")
        let first = try await repo.commit(["fork.go": "package app // fork\n"], message: "Change the fork's main")
        try await repo.push(asPullRequest: 9)
        let switcher = CheckoutSwitcher()

        let switched = try await switcher.switchTo(pullRequest: 9, of: "tamarinworks/app", headRefName: "main", in: repo.checkout)

        #expect(switched.name == "pr-9")
        #expect(switched.isFork)
        #expect(try await repo.git(["rev-parse", "HEAD"], in: repo.checkout) == first)
        #expect(try await repo.git(["rev-parse", "refs/heads/main"], in: repo.checkout) == main)

        // Coming back to it later fast-forwards the PR's branch.
        try await repo.git(["switch", "--quiet", "main"], in: repo.checkout)
        let second = try await repo.commit(["fork.go": "package app // fork, again\n"], message: "Change it again")
        try await repo.push(asPullRequest: 9)
        let again = try await switcher.switchTo(pullRequest: 9, of: "tamarinworks/app", headRefName: "main", in: repo.checkout)
        #expect(again.isAtPullRequestHead)
        #expect(try await repo.git(["rev-parse", "HEAD"], in: repo.checkout) == second)
    }

    @Test func aPullRequestTheRemoteDoesNotHaveIsRefused() async throws {
        let repo = try await FakeRepository()
        let before = try await repo.checkoutState()

        let error = try await #require(throws: CheckoutSwitchError.self) {
            try await CheckoutSwitcher().switchTo(pullRequest: 99, of: "tamarinworks/app", headRefName: "gone", in: repo.checkout)
        }

        #expect(error == .notOnRemote("refs/pull/99/head", remote: "origin"))
        #expect(try await repo.checkoutState() == before)
    }

    @Test func aGoModuleOpensInGoLandAndAnythingElseInVSCode() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let go = root.appending(path: "go")
        let nested = root.appending(path: "nested")
        let web = root.appending(path: "web")
        for directory in [go, nested.appending(path: "tools"), web] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "module example.com/go\n".write(to: go.appending(path: "go.mod"), atomically: true, encoding: .utf8)
        try "module example.com/tools\n".write(to: nested.appending(path: "tools/go.mod"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: web.appending(path: "package.json"), atomically: true, encoding: .utf8)

        #expect(Editor(for: go) == .goLand)
        #expect(Editor(for: nested) == .visualStudioCode, "only a go.mod at the root counts")
        #expect(Editor(for: web) == .visualStudioCode)
        #expect(Editor.goLand.bundleIdentifier == "com.jetbrains.goland")
        #expect(Editor.visualStudioCode.bundleIdentifier == "com.microsoft.VSCode")
    }
}

enum DirtyCase: Sendable {
    case untracked, modified, staged, merging
}
