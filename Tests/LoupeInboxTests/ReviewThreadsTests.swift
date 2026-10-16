import Foundation
import LoupeCore
import LoupeGit
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ReviewThreadsTests {
    @Test func threadsShowUnderTheLinesTheyEndOnAndTheRestAfterTheLastRow() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let id = pullRequest.id
        // On an added line, twice, one resolved; on a deleted line; outdated; on a line the diff
        // doesn't show; and on a vendored file.
        let added = try await app.conversations.startThread(on: id, path: "app.go", line: 11, body: "Why three?")
        let deleted = try await app.conversations.startThread(on: id, path: "app.go", line: 50, side: "LEFT", body: "Keep this?")
        let resolved = try await app.conversations.startThread(on: id, path: "app.go", line: 11, resolved: true, body: "Typo")
        let outdated = try await app.conversations.startThread(on: id, path: "app.go", line: 3, outdated: true, body: "Gone now")
        let hidden = try await app.conversations.startThread(on: id, path: "app.go", line: 30, body: "And here?")
        try await app.conversations.startThread(on: id, path: "vendor/example.com/lib/lib.go", line: 1, body: "Vendored?")
        let tab = try await app.open(pullRequest)

        #expect(tab.unresolvedThreadCount(of: "app.go") == 4)
        #expect(tab.unresolvedThreadCount(of: "vendor/example.com/lib/lib.go") == 1, "a hidden file's threads count too")
        #expect(tab.unresolvedThreadCount(of: "new.go") == 0)

        let file = try #require(tab.file("app.go"))
        let threads = try #require(tab.threads(on: tab.expandedFile(file)))
        #expect(threads.anchored.map { [$0.side.rawValue, String($0.line)] + $0.threads.map(\.id) } == [["RIGHT", "11", added, resolved], ["LEFT", "50", deleted]])
        #expect(threads.elsewhere.map(\.id) == [outdated, hidden])
        let multiLine = try #require(threads.anchored.first?.threads.first)
        #expect(multiLine.comments.map(\.bodyHTML) == ["<p dir=\"auto\">Why three?</p>"])

        // Rendered, each line's threads get a row straight under it and the rest come last.
        let blocks = threads.anchored.map { DiffBlock(id: "\($0.side):\($0.line)", placement: .after(side: $0.side, line: $0.line), height: 40) }
            + [DiffBlock(id: "elsewhere", placement: .end, height: 40)]
        let rendered = RenderedDiff(file: tab.expandedFile(file), blocks: blocks)
        #expect(rendered.text(ofRow: try #require(rendered.blockRows["right:11"]) - 1).hasSuffix("10b\n"))
        #expect(rendered.text(ofRow: try #require(rendered.blockRows["left:50"]) - 1).hasSuffix("50 line\n"))
        #expect(rendered.blockRows["elsewhere"] == rendered.rowStarts.count - 1)

        // Revealing the line a thread is on brings it into the diff.
        await tab.readContext(of: file)
        await tab.expandContext(of: file, ContextExpansion(hunk: 0, direction: .below))
        let expanded = try #require(tab.threads(on: tab.expandedFile(file)))
        #expect(expanded.anchored.contains { $0.side == .right && $0.line == 30 && $0.threads.map(\.id) == [hidden] })
        #expect(expanded.elsewhere.map(\.id) == [outdated])

        // They belong to the whole PR's diff, so a commit's shows none.
        let commit = try #require(tab.ready?.commits.first)
        await tab.showCommit(commit.oid)
        #expect(tab.threads(on: try #require(tab.file("app.go"))) == nil)
        #expect(tab.unresolvedThreadCount(of: "app.go") == nil)
        await tab.showCommit(nil)
        #expect(tab.threads(on: tab.expandedFile(file))?.anchored.count == 3)
    }

    @Test func threadsAreStoredWithWhereTheyAreAndShownBeforeGitHubAnswers() async throws {
        let app = try await ThreadsApp()
        let pullRequest = app.tabs.lists.pullRequests(in: .toReview)[0]
        try await app.conversations.add(pullRequest.id)
        let tab = try await app.open(pullRequest)
        let fetched = try #require(tab.conversation?.threads)

        // As captured on atrium#2928: a resolved thread over lines 22 to 30, and an outdated one
        // that only knows where it was made.
        let range = try #require(fetched.first)
        #expect(range.lines == 22...30)
        #expect(range.side == .right)
        #expect(range.resolvedBy == "rowan-ashby")
        #expect(range.viewerCanUnresolve && !range.viewerCanResolve && range.viewerCanReply)
        #expect(range.diffHunk.hasPrefix("@@ -0,0 +1,129 @@"))
        #expect(range.comments.first?.databaseId == 4_260_356_265)
        let outdated = fetched[1]
        #expect(outdated.isOutdated && outdated.line == nil && outdated.lines == 71...71)

        await app.conversations.fail()
        let nextRun = try #require(app.relaunch().tab(id: pullRequest.id))
        #expect(nextRun.conversation?.threads == fetched)
    }
}

@MainActor
struct ThreadRepliesTests {
    @Test func aReplyPostsAtOnceAndTheThreadsAreFetchedAgain() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        let thread = try #require(tab.thread(threadId))
        let pullRequest = tab.pullRequest

        tab.startReply(to: thread)
        let draft = try #require(tab.threadActivity.replies[threadId])
        draft.text = "  \n"
        #expect(!draft.canSend, "nothing to send")
        await tab.sendReply(to: thread)
        #expect(await app.conversations.repliesReceived.isEmpty)

        draft.text = "Good point, fixed in the next commit"
        await tab.sendReply(to: thread)

        let started = try #require(thread.comments.first?.databaseId)
        #expect(await app.conversations.repliesReceived == [.init(repository: pullRequest.repository, number: pullRequest.number, commentId: started, body: "Good point, fixed in the next commit")])
        #expect(tab.threadActivity.replies[threadId] == nil, "closed once posted")
        #expect(await app.conversations.threadFetches == 1, "only the threads, not the whole conversation")
        let replied = try #require(tab.thread(threadId))
        #expect(replied.comments.map(\.author?.login) == ["octocat", FakeGitHub.viewer])
        #expect(replied.comments.last?.bodyHTML == "<p dir=\"auto\">Good point, fixed in the next commit</p>")
        #expect(try app.store.conversation(of: pullRequest.id)?.threads == tab.conversation?.threads)
    }

    @Test func aRefusedReplyKeepsTheDraftAndSaysWhy() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        let thread = try #require(tab.thread(threadId))
        await app.conversations.refuseThreadChanges()
        tab.startReply(to: thread)
        let draft = try #require(tab.threadActivity.replies[threadId])
        draft.text = "A careful answer"

        await tab.sendReply(to: thread)

        #expect(tab.threadActivity.replies[threadId] === draft, "still open")
        #expect(draft.text == "A careful answer")
        #expect(draft.canSend, "so it can be sent again")
        #expect(tab.threadActivity.errors[threadId]?.contains("Resource not accessible") == true)
        #expect(tab.thread(threadId)?.comments.count == 1)

        tab.cancelReply(to: thread)
        #expect(tab.threadActivity.replies[threadId] == nil)
        #expect(tab.threadActivity.errors[threadId] == nil)
    }

    @Test func resolvingFoldsTheThreadAwayAndUnresolvingBringsItBack() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        #expect(tab.unresolvedThreadCount(of: "app.go") == 1)

        await tab.setResolved(true, thread: try #require(tab.thread(threadId)))
        let resolved = try #require(tab.thread(threadId))
        #expect(resolved.isResolved)
        #expect(resolved.resolvedBy == FakeGitHub.viewer, "as GitHub has it, fetched again")
        #expect(resolved.viewerCanUnresolve && !resolved.viewerCanResolve)
        #expect(!tab.threadActivity.expanded.contains(threadId))
        #expect(tab.unresolvedThreadCount(of: "app.go") == 0)

        await tab.setResolved(false, thread: resolved)
        #expect(tab.thread(threadId)?.isResolved == false)
        #expect(await app.conversations.resolutionsReceived == [.init(threadId: threadId, resolved: true), .init(threadId: threadId, resolved: false)])
        #expect(try app.store.conversation(of: tab.id)?.threads == tab.conversation?.threads)
    }

    @Test func aRefusedResolveIsPutBackAndSaysWhy() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        await app.conversations.refuseThreadChanges()

        await tab.setResolved(true, thread: try #require(tab.thread(threadId)))

        #expect(tab.thread(threadId)?.isResolved == false)
        #expect(tab.threadActivity.errors[threadId]?.contains("Couldn't resolve") == true)
        #expect(tab.threadActivity.resolving.isEmpty)
        #expect(await app.conversations.threadFetches == 0)
    }
}

@MainActor
struct NewCommentTests {
    @Test func theLinesShownTakeAComment() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let file = try #require(tab.file("app.go"))
        let commentable = try #require(tab.commentableAnchors(of: tab.expandedFile(file)))
        #expect(commentable.contains(DiffAnchor(path: "app.go", side: .right, line: 11)), "an added line")
        #expect(commentable.contains(DiffAnchor(path: "app.go", side: .left, line: 50)), "a deleted line")
        #expect(commentable.contains(DiffAnchor(path: "app.go", side: .right, line: 9)), "an unchanged line in a hunk")
        #expect(!commentable.contains(DiffAnchor(path: "app.go", side: .right, line: 30)), "a line hidden between hunks")
        #expect(!commentable.contains(DiffAnchor(path: "app.go", side: .left, line: 9)), "unchanged lines take comments on the new side")

        await tab.expandContext(of: file, ContextExpansion(hunk: 1, direction: .above))
        let revealed = try #require(tab.commentableAnchors(of: tab.expandedFile(file)))
        #expect(revealed.contains(DiffAnchor(path: "app.go", side: .right, line: 30)), "a line revealed around a hunk")
        #expect(!revealed.contains(DiffAnchor(path: "app.go", side: .left, line: 28)), "revealed lines take comments on the new side")

        await tab.showCommit(try #require(tab.ready?.commits.first).oid)
        #expect(tab.commentableAnchors(of: try #require(tab.file("app.go"))) == nil, "not on one commit's changes")
        #expect(await app.conversations.commentsReceived.isEmpty, "nothing is posted until a comment is sent")
    }

    @Test func aNewCommentPostsAtOnceOnTheHeadCommitAndShowsAsAThread() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let anchor = DiffAnchor(path: "app.go", side: .left, line: 50)
        tab.startComment(at: anchor)
        let draft = try #require(tab.threadActivity.newComment?.draft)
        draft.text = "Is anything still using this?"

        await tab.sendComment()

        let pullRequest = tab.pullRequest
        let head = try #require(tab.ready?.headOid)
        #expect(await app.conversations.commentsReceived == [
            .init(repository: pullRequest.repository, number: pullRequest.number, body: "Is anything still using this?", commitId: head, path: "app.go", line: 50, side: "LEFT"),
        ])
        #expect(tab.threadActivity.newComment == nil)
        #expect(await app.conversations.threadFetches == 1)
        let file = try #require(tab.file("app.go"))
        let threads = try #require(tab.threads(on: tab.expandedFile(file)))
        let posted = try #require(threads.anchored.first { $0.side == .left && $0.line == 50 }?.threads.first)
        #expect(posted.comments.map(\.author?.login) == [FakeGitHub.viewer])
        #expect(posted.comments.first?.bodyHTML == "<p dir=\"auto\">Is anything still using this?</p>")
        #expect(tab.unresolvedThreadCount(of: "app.go") == 2)
    }

    @Test func aCommentOnARevealedLinePostsWithItsNewLineNumber() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let file = try #require(tab.file("app.go"))
        await tab.expandContext(of: file, ContextExpansion(hunk: 1, direction: .above))
        let anchor = DiffAnchor(path: "app.go", side: .right, line: 30)
        #expect(tab.commentableAnchors(of: tab.expandedFile(file))?.contains(anchor) == true)
        tab.startComment(at: anchor)
        let draft = try #require(tab.threadActivity.newComment?.draft)
        draft.text = "Should this move too?"

        await tab.sendComment()

        let pullRequest = tab.pullRequest
        let head = try #require(tab.ready?.headOid)
        #expect(await app.conversations.commentsReceived == [
            .init(repository: pullRequest.repository, number: pullRequest.number, body: "Should this move too?", commitId: head, path: "app.go", line: 30, side: "RIGHT"),
        ])
        let threads = try #require(tab.threads(on: tab.expandedFile(file)))
        #expect(threads.anchored.contains { $0.side == .right && $0.line == 30 }, "shown under the revealed line")
    }

    @Test func aRefusedCommentKeepsTheDraftAndSaysWhy() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        await app.conversations.refuseThreadChanges()
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 10))
        let draft = try #require(tab.threadActivity.newComment?.draft)
        draft.text = "Rename this?"

        await tab.sendComment()

        #expect(tab.threadActivity.newComment?.draft === draft)
        #expect(draft.text == "Rename this?" && draft.canSend)
        #expect(tab.threadActivity.newCommentError?.contains("Resource not accessible") == true)
        #expect(tab.unresolvedThreadCount(of: "app.go") == 1)

        // Another line's "+" doesn't throw away what's written; cancelling does.
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 12))
        #expect(tab.threadActivity.newComment?.anchor.line == 10)
        tab.cancelComment()
        #expect(tab.threadActivity.newComment == nil && tab.threadActivity.newCommentError == nil)
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 12))
        #expect(tab.threadActivity.newComment?.anchor.line == 12)
    }
}

/// Following the conversation page's links to a thread.
@MainActor
struct ThreadLinksTests {
    @Test func showingAThreadOpensItsFileInTheWholePRsDiffScrolledToIt() async throws {
        let (_, tab, threadId) = try await ThreadsApp.withThread()
        let commit = try #require(tab.ready?.commits.last)
        await tab.showCommit(commit.oid)
        tab.selectedFile = "new.go"
        tab.section = .conversation

        await tab.follow(ThreadLink(.show, thread: threadId))

        #expect(tab.section == .files)
        #expect(tab.shownCommit == nil, "threads are placed on the whole PR's diff")
        #expect(tab.selectedFile == "app.go")
        #expect(tab.threadActivity.revealing == threadId, "for the diff to scroll to once drawn")
        #expect(tab.threadActivity.highlighted == threadId)
        #expect(tab.threadActivity.replies[threadId] == nil, "showing it doesn't start a reply")
        let file = try #require(tab.file("app.go"))
        let threads = try #require(tab.threads(on: tab.expandedFile(file)))
        #expect(threads.anchored.first { $0.line == 11 }?.threads.map(\.id) == [threadId], "under its line, where the diff scrolls")

        tab.threadActivity.didReveal(threadId)
        #expect(tab.threadActivity.revealing == nil, "scrolled to once")
    }

    @Test func aResolvedOrOutdatedThreadIsShownOpenWhereTheDiffPutsIt() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let resolved = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 11, resolved: true, body: "Typo")
        let outdated = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 3, outdated: true, body: "Gone now")
        let hidden = try await app.conversations.startThread(on: pullRequest.id, path: "vendor/example.com/lib/lib.go", line: 1, body: "Vendored?")
        let tab = try await app.open(pullRequest)

        await tab.follow(ThreadLink(.show, thread: resolved))
        #expect(tab.threadActivity.expanded.contains(resolved), "opened, not folded away")

        await tab.follow(ThreadLink(.show, thread: outdated))
        #expect(tab.threadActivity.revealing == outdated)
        #expect(tab.threads(on: tab.expandedFile(try #require(tab.file("app.go"))))?.elsewhere.map(\.id) == [outdated], "after the last row")

        await tab.follow(ThreadLink(.show, thread: hidden))
        #expect(tab.section == .files)
        #expect(tab.selectedFile == "vendor/example.com/lib/lib.go", "a hidden file, whose diff is made once it's shown")
        #expect(tab.threadActivity.revealing == hidden)
        #expect(tab.threadActivity.unshown == nil)
    }

    @Test func replyingFromTheConversationOpensTheComposerOnTheThreadInTheDiff() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()

        await tab.follow(ThreadLink(.reply, thread: threadId))

        #expect(tab.section == .files)
        #expect(tab.selectedFile == "app.go")
        #expect(tab.threadActivity.revealing == threadId)
        #expect(tab.threadActivity.replyingApart == nil, "written in the diff, not over the conversation")
        let draft = try #require(tab.threadActivity.replies[threadId])
        draft.text = "Fixed"
        await tab.sendReply(to: try #require(tab.thread(threadId)))
        #expect(await app.conversations.repliesReceived.map(\.body) == ["Fixed"])
    }

    @Test func aThreadTheDiffCantShowSaysWhyAndIsRepliedToOverTheConversation() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let gone = try await app.conversations.startThread(on: pullRequest.id, path: "removed.go", line: 4, outdated: true, body: "Still needed?")
        let tab = try await app.open(pullRequest)
        let selected = tab.selectedFile

        await tab.follow(ThreadLink(.show, thread: gone))

        #expect(tab.section == .conversation)
        #expect(tab.threadActivity.unshown?.threadId == gone)
        #expect(tab.threadActivity.unshown?.reason == "the PR no longer changes removed.go")
        #expect(tab.threadActivity.unshown?.isFileSelected == false)
        #expect(tab.selectedFile == selected)
        #expect(tab.threadActivity.revealing == nil)

        await tab.follow(ThreadLink(.reply, thread: gone))

        #expect(tab.section == .conversation)
        #expect(tab.threadActivity.unshown == nil)
        #expect(tab.threadActivity.replyingApart?.threadId == gone)
        let draft = try #require(tab.threadActivity.replies[gone])
        draft.text = "Yes, still needed"
        await tab.sendReply(to: try #require(tab.thread(gone)))
        #expect(await app.conversations.repliesReceived.map(\.body) == ["Yes, still needed"], "sent as a reply in the diff is")
        #expect(tab.threadActivity.replies[gone] == nil, "closed once posted")
    }

    @Test func resolveAndUnresolveActAtOnce() async throws {
        let (_, tab, threadId) = try await ThreadsApp.withThread()

        await tab.follow(ThreadLink(.resolve, thread: threadId))
        #expect(tab.thread(threadId)?.isResolved == true)
        #expect(tab.section == .conversation, "staying on the conversation")

        await tab.follow(ThreadLink(.unresolve, thread: threadId))
        #expect(tab.thread(threadId)?.isResolved == false)
    }
}

/// The app's models over the PR fixture and an in-memory store, with a conversation for each
/// PR from `FakeConversations`.
@MainActor
struct ThreadsApp {
    let github: FakeGitHub
    let details = FakePullRequestDetails()
    let store: PullRequestStore
    let tabs: TabsModel
    /// The PR's repo, kept as long as the app, as diffing a commit later reads its checkout.
    let repo: FakeRepository

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        repo = try await FakeRepository()
        tabs = Self.tabs(github, details, store)
        await tabs.lists.refresh()
    }

    var conversations: FakeConversations { details.conversations }

    /// A PR open in its tab, with one unresolved thread by someone else on an added line.
    static func withThread() async throws -> (ThreadsApp, PullRequestTab, String) {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let threadId = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 11, body: "Why three?")
        return (app, try await app.open(pullRequest), threadId)
    }

    /// Makes the first to-review PR, with the probe's conversation, change a 60-line `app.go`:
    /// line 10 becomes three (new lines 10 to 12) and line 50 goes. It also adds `new.go` and
    /// changes a vendored file, which is hidden.
    func pushPullRequest() async throws -> PullRequestSummary {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        try await conversations.add(listed.id, number: listed.number)
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let lines = (1...60).map { "\($0) line" }
        let branchPoint = try await repo.commit(["app.go": lines.joined(separator: "\n") + "\n"], message: "Start")
        try await repo.push()
        try await repo.switchTo("feature", creatingFrom: "main")
        var changed = lines
        changed.remove(at: 49)
        changed.replaceSubrange(9...9, with: ["10a", "10b", "10c"])
        try await repo.commit(["app.go": changed.joined(separator: "\n") + "\n", "vendor/example.com/lib/lib.go": "package lib // patched\n"], message: "Change app.go")
        let head = try await repo.commit(["new.go": "package app\n"], message: "Add new.go")
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

    /// Fresh models over the same store, as on the next launch.
    func relaunch() -> TabsModel {
        Self.tabs(github, details, store)
    }

    private static func tabs(_ github: FakeGitHub, _ details: FakePullRequestDetails, _ store: PullRequestStore) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        return TabsModel(lists: lists, store: store, client: details.client(), notifications: github.notifications())
    }
}

extension PullRequestTab {
    /// A file to review in the shown changes.
    func file(_ path: String) -> FileDiff? {
        guard case let .ready(changes)? = shownChanges else { return nil }
        return changes.files.first { $0.path == path }
    }

    var ready: ReviewDiff? {
        if case let .ready(diff) = phase { diff } else { nil }
    }

    func thread(_ id: String) -> ReviewThread? {
        conversation?.threads.first { $0.id == id }
    }
}

extension RenderedDiff {
    /// A row's text, gutter and all.
    func text(ofRow row: Int) -> String {
        let end = row + 1 < rowStarts.count ? rowStarts[row + 1] : text.length
        return (text.string as NSString).substring(with: NSRange(location: rowStarts[row], length: end - rowStarts[row]))
    }
}
