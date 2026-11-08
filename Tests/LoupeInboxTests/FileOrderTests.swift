@testable import LoupeFakeGitHub
import Foundation
import LoupeCore
import LoupeGit
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct FileOrderTests {
    @Test func filesAreListedByFolderUntilAskedForDependencyOrderForThatTabAlone() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: ["docs/b.md": "b\n", "docs/a.md": "a\n", "README.md": "readme\n"])
        let tab = try await app.open(pullRequest)
        #expect(tab.fileOrder == .directories, "folders as a tab opens")
        #expect(tab.fileGroups == nil)

        await tab.setFileOrder(.bottomUp)

        #expect(tab.fileOrder == .bottomUp)
        #expect(tab.fileGroups == [FileGraph.Group(files: ["docs/a.md", "docs/b.md", "README.md"], isStandalone: true)], "files using nothing list as the tree does")
        #expect(app.tabs.tabs.allSatisfy { $0 === tab || $0.fileOrder == .directories }, "only this tab")
        await tab.setFileOrder(.directories)
        #expect(tab.fileGroups == nil)
    }

    @Test func goFilesUseThePackagesTheyImportAndTestsTheirOwnPackage() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: ["go.mod": "module example.com/shop\n\ngo 1.22\n"], changing: [
            "model/user.go": "package model\n\ntype User struct{ Name string }\n",
            "store/users.go": "package store\n\nimport \"example.com/shop/model\"\n\nfunc Find() model.User { return model.User{} }\n",
            "store/users_test.go": "package store\n\nimport \"testing\"\n\nfunc TestFind(t *testing.T) { Find() }\n",
            "api/server.go": "package api\n\nimport (\n\t\"fmt\"\n\n\t\"example.com/shop/store\"\n)\n\nfunc Serve() { fmt.Println(store.Find()) }\n",
            "README.md": "# shop\n",
        ])
        let tab = try await app.open(pullRequest)

        await tab.setFileOrder(.bottomUp)

        #expect(outline(tab) == [
            "group",
            "  model/user.go",
            "  store/users.go",
            "  api/server.go",
            "  store/users_test.go",
            "standalone",
            "  README.md",
        ])
        await tab.setFileOrder(.topDown)
        #expect(outline(tab) == [
            "group",
            "  api/server.go",
            "  store/users_test.go",
            "  store/users.go",
            "  model/user.go",
            "standalone",
            "  README.md",
        ])
        #expect(tab.selectedFile == "api/server.go", "the file the PR opened on stays shown")
        tab.selectAdjacentFile(1)
        #expect(tab.selectedFile == "store/users_test.go", "moving on follows the list")
        #expect(tab.nextUnviewedFile(after: "store/users_test.go") == "store/users.go")
    }

    @Test func goModulesNestedInTheRepoResolveFromTheirOwnGoMod() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: ["services/billing/go.mod": "module github.com/acme/billing\n"], changing: [
            "services/billing/invoice/invoice.go": "package invoice\n\ntype Invoice struct{}\n",
            "services/billing/cmd/billing/main.go": "package main\n\nimport `github.com/acme/billing/invoice`\n\nvar _ invoice.Invoice\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == ["group", "  services/billing/invoice/invoice.go", "  services/billing/cmd/billing/main.go"])
    }
}

/// The shown changes' groups, each as a line saying what kind it is, then its files indented.
@MainActor
private func outline(_ tab: PullRequestTab) -> [String] {
    (tab.fileGroups ?? []).flatMap { [$0.isStandalone ? "standalone" : "group"] + $0.files.map { "  \($0)" } }
}

extension ThreadsApp {
    /// Makes the first to-review PR one commit writing `files` (nil deletes) after `base` on
    /// main, and returns it as the lists now have it.
    func pushPullRequest(startingWith base: [String: String?] = [".gitignore": "*.tmp\n"], changing files: [String: String?]) async throws -> PullRequestSummary {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        try await conversations.add(listed.id, number: listed.number)
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = try await repo.commit(base, message: "Start")
        try await repo.push()
        try await repo.switchTo("feature", creatingFrom: "main")
        let head = try await repo.commit(files, message: "Change files")
        try await repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = head; $0.baseRefOid = branchPoint }
        await conversations.setHead(head, of: listed.id)
        await tabs.lists.refresh()
        return try #require(tabs.lists.pullRequest(id: listed.id))
    }
}
