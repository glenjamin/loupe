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
