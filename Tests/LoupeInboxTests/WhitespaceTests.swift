@testable import LoupeFakeGitHub
import Foundation
import LoupeCore
import LoupeGit
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct WhitespaceTests {
    @Test func hidingWhitespaceKeepsEveryFileListedButShowsAndCountsOnlyRealChanges() async throws {
        let (app, pullRequest) = try await WhitespaceApp.pushPullRequest()
        let tab = try await app.open(pullRequest)
        #expect(!tab.hidesWhitespace, "off as a tab opens")
        let paths = try #require(tab.shownFiles).map(\.path)
        #expect(tab.diffStat(of: .all) == DiffStat(files: 2, additions: 12, deletions: 12))
        #expect(try #require(tab.file("indent.go")).hunks.count == 1)

        await tab.setHidesWhitespace(true)

        #expect(tab.hidesWhitespace && tab.shownIgnoresWhitespace)
        #expect(try #require(tab.shownFiles).map(\.path) == paths, "a file only reindented is still listed")
        let indent = try #require(tab.file("indent.go"))
        #expect(indent.isWhitespaceOnly && indent.hunks.isEmpty)
        #expect((indent.additions, indent.deletions) == (0, 0))
        let mixed = try #require(tab.file("mixed.go"))
        #expect(!mixed.isWhitespaceOnly)
        #expect(mixed.hunks.flatMap(\.lines).map(\.kind) == [
            .context(old: 4, new: 4), .context(old: 5, new: 5), .context(old: 6, new: 6),
            .deletion(old: 7), .addition(new: 7),
            .context(old: 8, new: 8), .context(old: 9, new: 9), .context(old: 10, new: 10),
        ])
        #expect(mixed.hunks[0].lines[2].text == "    6 line", "an unchanged line reads as the head has it")
        #expect((mixed.additions, mixed.deletions) == (1, 1))
        #expect(tab.diffStat(of: .all) == DiffStat(files: 2, additions: 1, deletions: 1), "a file only reindented still counts as a file")
        #expect(app.tabs.tabs.allSatisfy { $0 === tab || !$0.hidesWhitespace }, "only this tab hides it")

        await tab.setHidesWhitespace(false)
        #expect(tab.diffStat(of: .all) == DiffStat(files: 2, additions: 12, deletions: 12))
        #expect((try #require(tab.file("indent.go")).additions) == 10)
    }

    @Test func commitsAndHiddenFilesAreCountedWithoutWhitespaceWhileItsHidden() async throws {
        let (app, pullRequest) = try await WhitespaceApp.pushPullRequest()
        let tab = try await app.open(pullRequest)
        let commits = try #require(tab.ready?.commits)
        await tab.countCommitChanges()
        #expect(tab.diffStat(of: .commit(commits[0].oid)) == DiffStat(files: 1, additions: 10, deletions: 10))

        await tab.setHidesWhitespace(true)
        #expect(tab.diffStat(of: .commit(commits[0].oid)) == DiffStat(files: 1, additions: 10, deletions: 10), "as it was until counted again")
        await tab.countCommitChanges()
        #expect(tab.diffStat(of: .commit(commits[0].oid)) == DiffStat(files: 1, additions: 0, deletions: 0))
        #expect(tab.diffStat(of: .commit(commits[1].oid)) == DiffStat(files: 1, additions: 1, deletions: 1))
        let vendored = try #require(tab.shownHidden?.first { $0.path == "vendor/example.com/lib/lib.go" })
        #expect((vendored.additions, vendored.deletions) == (0, 0))

        await tab.setHidesWhitespace(false)
        #expect(tab.diffStat(of: .commit(commits[0].oid)) == DiffStat(files: 1, additions: 10, deletions: 10))
        let counted = try #require(tab.shownHidden?.first { $0.path == vendored.path })
        #expect((counted.additions, counted.deletions) == (1, 1))
    }

    @Test func eachWayIsKeptSoTogglingBackNeedsNoGit() async throws {
        let (app, pullRequest) = try await WhitespaceApp.pushPullRequest()
        let tab = try await app.open(pullRequest)
        let commit = try #require(tab.ready?.commits.first)
        await tab.setHidesWhitespace(true)
        await tab.show(.commit(commit.oid))
        await tab.setHidesWhitespace(false)
        await tab.show(.all)

        // With the checkout gone, only what's kept can be shown.
        try FileManager.default.moveItem(at: app.repo.checkout, to: app.repo.root.appending(path: "moved"))
        await tab.setHidesWhitespace(true)
        #expect(try #require(tab.file("indent.go")).isWhitespaceOnly)
        await tab.show(.commit(commit.oid))
        #expect(try #require(tab.file("indent.go")).isWhitespaceOnly)
        await tab.setHidesWhitespace(false)
        #expect(try #require(tab.file("indent.go")).hunks.count == 1)
        #expect(tab.shownChoice == .commit(commit.oid), "the commit stays picked")
    }

    @Test func aCommitsChangesHideWhitespaceToo() async throws {
        let (app, pullRequest) = try await WhitespaceApp.pushPullRequest()
        let tab = try await app.open(pullRequest)
        await tab.setHidesWhitespace(true)
        let commits = try #require(tab.ready?.commits)

        await tab.show(.commit(commits[0].oid))
        #expect(tab.shownFiles?.map(\.path) == ["indent.go"])
        #expect(try #require(tab.file("indent.go")).isWhitespaceOnly)

        await tab.show(.commit(commits[1].oid))
        let mixed = try #require(tab.file("mixed.go"))
        #expect(mixed.ignoresWhitespace && mixed.hunks.flatMap(\.lines).count(where: \.isAddition) == 1)
        #expect(tab.commentableAnchors(of: mixed)?.contains(DiffAnchor(path: "mixed.go", side: .right, line: 6)) == true)
    }

    @Test func threadsLandOnTheirLinesAndCommentsTakeTheFilesLineNumbers() async throws {
        let (app, pullRequest) = try await WhitespaceApp.pushPullRequest()
        let id = pullRequest.id
        // On the reindented line, as the head and the base number it, and on the changed line.
        let reindented = try await app.conversations.startThread(on: id, path: "mixed.go", line: 6, body: "Why indent?")
        let before = try await app.conversations.startThread(on: id, path: "mixed.go", line: 6, side: "LEFT", body: "Was fine")
        let changed = try await app.conversations.startThread(on: id, path: "mixed.go", line: 7, side: "LEFT", body: "Keep this?")
        let tab = try await app.open(pullRequest)
        await tab.setHidesWhitespace(true)

        let mixed = tab.expandedFile(try #require(tab.file("mixed.go")))
        let threads = try #require(tab.threads(on: mixed))
        #expect(Set(threads.anchored.map { "\($0.side.rawValue) \($0.line) \($0.threads.map(\.id))" }) == [
            "RIGHT 6 \([reindented])", "LEFT 6 \([before])", "LEFT 7 \([changed])",
        ])
        #expect(threads.elsewhere.isEmpty)
        // Rendered, each sits under its row, though line 6 shows unchanged.
        let blocks = threads.anchored.map { DiffBlock(id: "\($0.side):\($0.line)", placement: .after(side: $0.side, line: $0.line), height: 40) }
        let rendered = RenderedDiff(file: mixed, blocks: blocks)
        #expect(rendered.text(ofRow: try #require(rendered.blockRows["right:6"]) - 1).hasSuffix("    6 line\n"))
        #expect(rendered.text(ofRow: try #require(rendered.blockRows["left:7"]) - 1).hasSuffix("7 line\n"))

        // A comment on the reindented line is on line 6 of the head, which GitHub's diff adds.
        tab.startComment(at: DiffAnchor(path: "mixed.go", side: .right, line: 6), from: DiffAnchor(path: "mixed.go", side: .right, line: 5))
        try #require(tab.threadActivity.newComment).draft.text = "Tidy"
        await tab.sendComment()
        let sent = await app.conversations.commentsReceived.last
        #expect(sent?.path == "mixed.go" && sent?.line == 6 && sent?.side == "RIGHT" && sent?.startLine == 5)
        #expect(sent?.commitId == pullRequest.headRefOid)
    }

    @Test func revealedLinesAndHiddenFilesAreKeptApartForEachWay() async throws {
        let (app, pullRequest) = try await WhitespaceApp.pushPullRequest()
        let tab = try await app.open(pullRequest)
        await tab.setHidesWhitespace(true)
        let mixed = try #require(tab.file("mixed.go"))
        await tab.expandContext(of: mixed, ContextExpansion(hunk: 0, direction: .above))
        #expect(tab.expandedFile(mixed).hunks[0].newStart == 1)
        #expect(tab.expandedFile(mixed).hunks[0].lines[2].kind == .context(old: 3, new: 3))

        await tab.setHidesWhitespace(false)
        let plain = try #require(tab.file("mixed.go"))
        #expect(!tab.hasRevealedContext(of: plain), "the plain diff's hunks are its own")
        await tab.setHidesWhitespace(true)
        #expect(tab.hasRevealedContext(of: try #require(tab.file("mixed.go"))))

        // A vendored file only reformatted says so once diffed.
        let vendored = "vendor/example.com/lib/lib.go"
        await tab.diffHiddenFile(vendored)
        guard case let .ready(hidden)? = tab.hiddenFileDiff(of: vendored) else { throw Unexpected.notDiffed }
        #expect(hidden.isWhitespaceOnly && (hidden.additions, hidden.deletions) == (0, 0))
        await tab.setHidesWhitespace(false)
        #expect(tab.hiddenFileDiff(of: vendored).map { _ in "diffed" } == nil, "diffed again the other way when shown")
    }

    @Test func aReloadKeepsWhitespaceHidden() async throws {
        let (app, pullRequest) = try await WhitespaceApp.pushPullRequest()
        let tab = try await app.open(pullRequest)
        await tab.setHidesWhitespace(true)
        await tab.reload()
        #expect(tab.hidesWhitespace && tab.shownIgnoresWhitespace)
        #expect(try #require(tab.file("indent.go")).isWhitespaceOnly)
    }
}

private enum Unexpected: Error {
    case notDiffed
}

/// The threads app's models over a PR of two commits: the first reindents all ten lines of
/// `indent.go`; the second reindents line 6 of `mixed.go`, changes its line 7 and reformats a
/// vendored file.
@MainActor
private enum WhitespaceApp {
    static func pushPullRequest() async throws -> (ThreadsApp, PullRequestSummary) {
        let app = try await ThreadsApp()
        let repo = app.repo
        let listed = try #require(app.tabs.lists.pullRequests(in: .toReview).first)
        try await app.conversations.add(listed.id, number: listed.number)
        try await app.store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let indent = (1...10).map { "\($0) indented" }
        let mixed = (1...10).map { "\($0) line" }
        let branchPoint = try await repo.commit(["indent.go": lines(indent), "mixed.go": lines(mixed)], message: "Start")
        try await repo.push()
        try await repo.switchTo("feature", creatingFrom: "main")
        try await repo.commit(["indent.go": lines(indent.map { "\t" + $0 })], message: "Reindent")
        var changed = mixed
        changed[5] = "    6 line"
        changed[6] = "7 changed"
        let head = try await repo.commit(["mixed.go": lines(changed), "vendor/example.com/lib/lib.go": "package  lib\n"], message: "Change mixed.go")
        try await repo.push(asPullRequest: listed.number)
        try await app.github.edit(listed.id) { $0.headRefOid = head; $0.baseRefOid = branchPoint }
        await app.conversations.setHead(head, of: listed.id)
        await app.tabs.lists.refresh()
        return (app, try #require(app.tabs.lists.pullRequest(id: listed.id)))
    }

    private static func lines(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }
}

private extension PullRequestTab {
    /// The files to review in the shown changes.
    var shownFiles: [FileDiff]? {
        guard case let .ready(changes)? = shownChanges else { return nil }
        return changes.files
    }

    /// The hidden files in the shown changes.
    var shownHidden: [ChangedFile]? {
        guard case let .ready(changes)? = shownChanges else { return nil }
        return changes.hidden
    }
}
