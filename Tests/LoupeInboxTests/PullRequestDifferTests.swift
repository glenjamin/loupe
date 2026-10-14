import Foundation
import LoupeGit
import Testing

struct PullRequestDifferTests {
    @Test func diffsAPullRequestAgainstWhereItBranchedOffLeavingOutHiddenPaths() async throws {
        let repo = try FakeRepository()
        let branchPoint = try repo.git(["rev-parse", "HEAD"], in: repo.checkout)
        try repo.switchTo("feature", creatingFrom: "main")
        try repo.commit([
            "app.go": "package app\n\nfunc Hello() string { return \"hello, world\" }\n",
            "vendor/example.com/lib/new.go": "package lib\n\nfunc New() {}\n",
            "go.sum": "example.com/lib v1.1.0 h1:def\n",
            "gen/schema.go": "package gen // regenerated\n",
            "vendor/patched/fix.go": "package patched\n",
        ], message: "Greet the world")
        let head = try repo.rename("README", to: "README.md", message: "Rename the readme")
        try repo.push(asPullRequest: 7)
        // The base moves on after the PR branched, and the checkout hasn't fetched it.
        try repo.switchTo("main")
        let base = try repo.commit(["other.go": "package app\n"], message: "Meanwhile on main")
        try repo.push()
        let before = try repo.checkoutState()

        let differ = PullRequestDiffer()
        let fetched = try await differ.fetch(number: 7, baseRefName: "main", baseRefOid: base, in: repo.checkout)
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
        #expect(diff.hiddenPaths.sorted() == ["gen/schema.go", "go.sum", "vendor/example.com/lib/new.go"])

        #expect(try repo.git(["rev-parse", "refs/loupe/pull/7/head"], in: repo.checkout) == head)
        #expect(try repo.checkoutState() == before)
    }

    @Test func fetchesTheBaseBranchWhenItsCommitIsUnknown() async throws {
        let repo = try FakeRepository()
        try repo.switchTo("feature", creatingFrom: "main")
        try repo.commit(["app.go": "package app\n"], message: "Simplify")
        try repo.push(asPullRequest: 3)
        try repo.switchTo("main")
        try repo.commit(["app.go": "package app // moved on\n"], message: "Diverge")
        try repo.push()
        let branchPoint = try repo.git(["rev-parse", "HEAD"], in: repo.checkout)

        let differ = PullRequestDiffer()
        let fetched = try await differ.fetch(number: 3, baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        let diff = try await differ.diff(fetched, in: repo.checkout)

        #expect(diff.mergeBase == branchPoint)
        #expect(diff.text.contains("-func Hello()"))
        #expect(!diff.text.contains("moved on"))
    }

    @Test func aPullRequestTheRemoteDoesNotHaveFailsWithGitsMessage() async throws {
        let repo = try FakeRepository()

        let error = try await #require(throws: GitError.self) {
            try await PullRequestDiffer().fetch(number: 99, baseRefName: "main", baseRefOid: nil, in: repo.checkout)
        }

        #expect(error.message.contains("refs/pull/99/head"))
        #expect(error.localizedDescription.contains("git fetch"))
    }
}
