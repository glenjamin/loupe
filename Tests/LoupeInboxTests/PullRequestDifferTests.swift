import Foundation
import LoupeCore
import LoupeGit
import Testing

struct PullRequestDifferTests {
    @Test func diffsAPullRequestAgainstWhereItBranchedOffLeavingOutHiddenPaths() async throws {
        let repo = try await FakeRepository()
        let branchPoint = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try await repo.switchTo("feature", creatingFrom: "main")
        try await repo.commit([
            "app.go": "package app\n\nfunc Hello() string { return \"hello, world\" }\n",
            "vendor/example.com/lib/new.go": "package lib\n\nfunc New() {}\n",
            "go.sum": "example.com/lib v1.1.0 h1:def\n",
            "gen/schema.go": "package gen // regenerated\n",
            "vendor/patched/fix.go": "package patched\n",
        ], message: "Greet the world")
        let head = try await repo.rename("README", to: "README.md", message: "Rename the readme")
        try await repo.push(asPullRequest: 7)
        // The base moves on after the PR branched, and the checkout hasn't fetched it.
        try await repo.switchTo("main")
        let base = try await repo.commit(["other.go": "package app\n"], message: "Meanwhile on main")
        try await repo.push()
        let before = try await repo.checkoutState()

        let differ = PullRequestDiffer()
        let fetched = try await differ.fetch(number: 7, of: "tamarinworks/app", baseRefName: "main", baseRefOid: base, in: repo.checkout)
        let diff = try await differ.diff(fetched, in: repo.checkout)

        #expect(fetched.headOid == head)
        #expect(diff.headOid == head)
        #expect(diff.mergeBase == branchPoint)
        #expect(diff.text.contains("diff --git a/app.go b/app.go"))
        #expect(diff.text.contains("+func Hello() string { return \"hello, world\" }"))
        #expect(diff.text.contains("rename from README\nrename to README.md"))
        // `.gitattributes` keeps this vendored path in review.
        #expect(diff.text.contains("diff --git a/vendor/patched/fix.go b/vendor/patched/fix.go"))
        for left in ["vendor/example.com", "go.sum", "gen/schema.go", "other.go"] {
            #expect(!diff.text.contains(left), "\(left) should be left out")
        }
        #expect(diff.hidden.sorted { $0.path < $1.path } == [
            ChangedFile(path: "gen/schema.go", change: .modified, additions: 1, deletions: 1),
            ChangedFile(path: "go.sum", change: .modified, additions: 1, deletions: 1),
            ChangedFile(path: "vendor/example.com/lib/new.go", change: .added, additions: 3),
        ])

        #expect(try await repo.git(["rev-parse", "refs/loupe/pull/7/head"], in: repo.checkout) == head)
        #expect(try await repo.checkoutState() == before)
    }

    @Test func listsThePullRequestsCommitsOldestFirstAndDiffsEachOnItsOwn() async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("feature", creatingFrom: "main")
        let first = try await repo.commit(["app.go": "package app // first\n", "go.sum": "example.com/lib v1.1.0 h1:def\n"], message: "First change")
        let second = try await repo.commit(["main.go": "package main\n"], message: "Second change, with a comma, and more")
        let third = try await repo.commit(["app.go": "package app // third\n"], message: "Third change")
        try await repo.push(asPullRequest: 5)

        let differ = PullRequestDiffer()
        let fetched = try await differ.fetch(number: 5, of: "tamarinworks/app", baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        let diff = try await differ.diff(fetched, in: repo.checkout)

        #expect(diff.commits.map(\.oid) == [first, second, third])
        #expect(diff.commits.map(\.headline) == ["First change", "Second change, with a comma, and more", "Third change"])

        let one = try await differ.diff(diff.commits[0].range, in: repo.checkout)
        #expect(one.text.contains("+package app // first"))
        #expect(!one.text.contains("main.go"))
        #expect(one.hidden == [ChangedFile(path: "go.sum", change: .modified, additions: 1, deletions: 1)])
        #expect(!one.text.contains("go.sum"))

        let three = try await differ.diff(diff.commits[2].range, in: repo.checkout)
        #expect(three.text.contains("-package app // first\n+package app // third"))
        #expect(!three.text.contains("main.go"))
        #expect(three.hidden.isEmpty)
    }

    @Test func aRootCommitIsDiffedFromNothing() async throws {
        let repo = try await FakeRepository()
        // A history started afresh then merged with its base, so its first commit has no parent.
        let contributor = repo.contributorDirectory
        try await repo.git(["switch", "--quiet", "--orphan", "fresh"], in: contributor)
        let root = try await repo.commit(["fresh.go": "package fresh\n"], message: "Start afresh")
        try await repo.git(["merge", "--quiet", "--allow-unrelated-histories", "--no-edit", "main"], in: contributor)
        try await repo.push(asPullRequest: 4)

        let differ = PullRequestDiffer()
        let fetched = try await differ.fetch(number: 4, of: "tamarinworks/app", baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        let diff = try await differ.diff(fetched, in: repo.checkout)
        let first = try #require(diff.commits.first)
        let changes = try await differ.diff(first.range, in: repo.checkout)

        #expect(first.oid == root)
        #expect(changes.text.contains("new file mode"))
        #expect(changes.text.contains("+package fresh"))
        #expect(!changes.text.contains("app.go"))
    }

    @Test func listsHiddenPathsWithWhatHappenedToEachAndDiffsOneOnItsOwn() async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("feature", creatingFrom: "main")
        try await repo.commit([
            "app.go": "package app // kept\n",
            "go.sum": "example.com/lib v1.1.0 h1:def\n",
            "vendor/example.com/lib/lib.go": nil,
            "vendor/example.com/other/other.go": "package other\n",
            "vendor/example.com/other/logo.png": "PNG\0\u{1}binary",
        ], message: "Bump dependencies")
        try await repo.rename("gen/schema.go", to: "gen/schema_v2.go", message: "Rename the schema")
        try await repo.push(asPullRequest: 8)

        let differ = PullRequestDiffer()
        let fetched = try await differ.fetch(number: 8, of: "tamarinworks/app", baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        let diff = try await differ.diff(fetched, in: repo.checkout)

        // Each with its line counts from the start, though not yet diffed.
        #expect(diff.hidden.sorted { $0.path < $1.path } == [
            ChangedFile(path: "gen/schema_v2.go", change: .renamed(from: "gen/schema.go", similarity: 100)),
            ChangedFile(path: "go.sum", change: .modified, additions: 1, deletions: 1),
            ChangedFile(path: "vendor/example.com/lib/lib.go", change: .deleted, deletions: 1),
            ChangedFile(path: "vendor/example.com/other/logo.png", change: .added, isBinary: true),
            ChangedFile(path: "vendor/example.com/other/other.go", change: .added, additions: 1),
        ])

        let sum = try #require(diff.hidden.first { $0.path == "go.sum" })
        let sumDiff = DiffParser.parse(try await differ.diff(of: sum, in: diff.range, checkout: repo.checkout))
        #expect(sumDiff.map(\.path) == ["go.sum"])
        #expect(sumDiff.first?.hunks.first?.lines.map(\.text) == ["example.com/lib v1.0.0 h1:abc", "example.com/lib v1.1.0 h1:def"])

        let renamed = try #require(diff.hidden.first { $0.path == "gen/schema_v2.go" })
        let renamedDiff = DiffParser.parse(try await differ.diff(of: renamed, in: diff.range, checkout: repo.checkout))
        #expect(renamedDiff.map(\.path) == ["gen/schema_v2.go"])
        #expect(renamedDiff.first?.change == .renamed(from: "gen/schema.go", similarity: 100))
    }

    @Test func fetchesTheBaseBranchWhenItsCommitIsUnknown() async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("feature", creatingFrom: "main")
        try await repo.commit(["app.go": "package app\n"], message: "Simplify")
        try await repo.push(asPullRequest: 3)
        try await repo.switchTo("main")
        try await repo.commit(["app.go": "package app // moved on\n"], message: "Diverge")
        try await repo.push()
        let branchPoint = try await repo.git(["rev-parse", "HEAD"], in: repo.checkout)

        let differ = PullRequestDiffer()
        let fetched = try await differ.fetch(number: 3, of: "tamarinworks/app", baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        let diff = try await differ.diff(fetched, in: repo.checkout)

        #expect(diff.mergeBase == branchPoint)
        #expect(diff.text.contains("-func Hello()"))
        #expect(!diff.text.contains("moved on"))
    }

    @Test func fetchesEachPullRequestFromTheRemoteForItsRepo() async throws {
        // A fork's checkout: origin is the fork, upstream the repo it was forked from, and each
        // has its own PR 3.
        let repo = try await FakeRepository()
        try await repo.addRemote("upstream", as: "git@github.com:honeycombio/app.git")
        try await repo.switchTo("fork-change", creatingFrom: "main")
        let forkHead = try await repo.commit(["fork.go": "package app // fork\n"], message: "Change the fork")
        try await repo.push(asPullRequest: 3)
        try await repo.switchTo("upstream-change", creatingFrom: "main")
        let upstreamHead = try await repo.commit(["app.go": "package app // upstream\n"], message: "Change upstream")
        try await repo.push(asPullRequest: 3, to: "upstream")
        let before = try await repo.checkoutState()

        let differ = PullRequestDiffer()
        let upstream = try await differ.fetch(number: 3, of: "honeycombio/app", baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        let upstreamDiff = try await differ.diff(upstream, in: repo.checkout)

        #expect(upstream.headOid == upstreamHead)
        #expect(upstream.base == "refs/remotes/upstream/main")
        #expect(upstreamDiff.text.contains("+package app // upstream"))
        #expect(!upstreamDiff.text.contains("fork.go"))

        let fork = try await differ.fetch(number: 3, of: "tamarinworks/app", baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        let forkDiff = try await differ.diff(fork, in: repo.checkout)

        #expect(fork.headOid == forkHead)
        #expect(fork.base == "refs/remotes/origin/main")
        #expect(forkDiff.text.contains("+package app // fork"))
        #expect(try await repo.checkoutState() == before)
    }

    @Test func aPullRequestTheRemoteDoesNotHaveFailsWithGitsMessage() async throws {
        let repo = try await FakeRepository()

        let error = try await #require(throws: GitError.self) {
            try await PullRequestDiffer().fetch(number: 99, of: "tamarinworks/app", baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        }

        #expect(error.message.contains("refs/pull/99/head"))
        #expect(error.localizedDescription.contains("git fetch"))
    }

    @Test func readsAFileAsItIsAtThePullRequestsHeadAndAtItsBase() async throws {
        let repo = try await FakeRepository()
        try await repo.switchTo("feature", creatingFrom: "main")
        try await repo.commit(["docs/guide.md": "# Guide\n\nNew words.\n", "README": nil], message: "Write a guide")
        try await repo.push(asPullRequest: 4)
        let before = try await repo.checkoutState()

        let differ = PullRequestDiffer()
        let diff = try await differ.diff(differ.fetch(number: 4, of: "tamarinworks/app", baseRefName: "main", baseRefOid: nil, in: repo.checkout), in: repo.checkout)

        #expect(try await differ.contents(of: "docs/guide.md", at: diff.headOid, in: repo.checkout) == "# Guide\n\nNew words.\n")
        #expect(try await differ.contents(of: "README", at: diff.mergeBase, in: repo.checkout) == "An app.\n", "a deleted file is still there at the base")
        await #expect(throws: GitError.self) {
            try await differ.contents(of: "README", at: diff.headOid, in: repo.checkout)
        }
        #expect(try await repo.checkoutState() == before)
    }
}
