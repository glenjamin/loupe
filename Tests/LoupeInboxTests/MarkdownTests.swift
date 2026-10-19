import Foundation
import LoupeCore
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct MarkdownTests {
    @Test func aMarkdownFileIsRenderedByGitHubFromItsTextAtTheHeadOnceAndKept() async throws {
        let app = try await MarkdownApp()
        let repo = try await FakeRepository()
        let pullRequest = try await app.pushPullRequest(in: repo, changing: [
            "docs/guide.md": "# Guide\n\nNew words & more.\n",
            "app.go": "package app // changed\n",
        ])
        let tab = try await app.open(pullRequest)
        let guide = try #require(tab.file("docs/guide.md"))

        let source = try #require(tab.markdownSource(of: guide))
        #expect(source.oid == pullRequest.headRefOid)
        #expect(tab.markdownSource(of: try #require(tab.file("app.go"))) == nil, "only markdown files render")
        #expect(tab.markdown.rendering(of: source) == nil)

        await tab.renderMarkdown(source)
        #expect(tab.markdown.rendering(of: source) == .ready("<h1>Guide</h1>\n<p>New words &amp; more.</p>"))
        #expect(await app.markdown.requests == [
            FakeMarkdown.Request(text: "# Guide\n\nNew words & more.\n", mode: "gfm", context: pullRequest.repository),
        ])

        await tab.renderMarkdown(source)
        #expect(await app.markdown.requests.count == 1, "a file's rendering at a head is kept")
    }

    @Test func aDeletedMarkdownFileRendersAsItWasAtTheBase() async throws {
        let app = try await MarkdownApp()
        let repo = try await FakeRepository()
        let pullRequest = try await app.pushPullRequest(in: repo, startingWith: ["OLD.md": "# Old\n"], changing: ["OLD.md": nil])
        let tab = try await app.open(pullRequest)

        let old = try #require(tab.file("OLD.md"))
        let source = try #require(tab.markdownSource(of: old))
        #expect(source.oid == pullRequest.baseRefOid)
        await tab.renderMarkdown(source)
        #expect(tab.markdown.rendering(of: source) == .ready("<h1>Old</h1>"))
    }

    @Test func aFailedRenderingSaysWhyAndCanBeTriedAgain() async throws {
        let app = try await MarkdownApp()
        let repo = try await FakeRepository()
        let pullRequest = try await app.pushPullRequest(in: repo, changing: ["notes.markdown": "Notes.\n"])
        let tab = try await app.open(pullRequest)
        let notes = try #require(tab.file("notes.markdown"))
        let source = try #require(tab.markdownSource(of: notes))

        await app.markdown.fail()
        await tab.renderMarkdown(source)
        guard case let .failed(message)? = tab.markdown.rendering(of: source) else {
            Issue.record("expected a failure, got \(String(describing: tab.markdown.rendering(of: source)))")
            return
        }
        #expect(message.contains("500"))

        await app.markdown.recover()
        await tab.renderMarkdown(source)
        #expect(tab.markdown.rendering(of: source) == .ready("<p>Notes.</p>"))
    }

    @Test func eachFileShowsItsSourceUntilChosenRenderedAndKeepsTheChoice() async throws {
        let app = try await MarkdownApp()
        let repo = try await FakeRepository()
        let pullRequest = try await app.pushPullRequest(in: repo, changing: ["a.md": "A\n", "b.md": "B\n"])
        let tab = try await app.open(pullRequest)

        #expect(!tab.markdown.isRendered("a.md"))
        tab.markdown.setRendered(true, path: "a.md")
        tab.selectedFile = "b.md"
        #expect(!tab.markdown.isRendered("b.md"))
        tab.selectedFile = "a.md"
        #expect(tab.markdown.isRendered("a.md"))
        tab.markdown.setRendered(false, path: "a.md")
        #expect(!tab.markdown.isRendered("a.md"))
    }

    @Test func aDraftPreviewsAsGitHubRendersItInThePullRequestsRepoOnceAndKept() async throws {
        let app = try await MarkdownApp()
        let tab = try await app.openFirstPullRequest()
        let draft = "# Looks good\n\nThanks @octocat, see #12 & `run()`."

        #expect(tab.markdown.preview(ofDraft: draft) == .rendering, "a draft not yet rendered is waited for")
        await tab.renderDraft(draft)
        #expect(tab.markdown.preview(ofDraft: draft) == .ready("<h1>Looks good</h1>\n<p>Thanks @octocat, see #12 &amp; `run()`.</p>"))
        #expect(await app.markdown.requests == [
            FakeMarkdown.Request(text: draft, mode: "gfm", context: tab.pullRequest.repository),
        ])

        await tab.renderDraft(draft)
        #expect(await app.markdown.requests.count == 1, "a draft's rendering is kept")

        let edited = draft + "\n\nOne more thing."
        #expect(tab.markdown.preview(ofDraft: edited) == .rendering)
        await tab.renderDraft(edited)
        #expect(tab.markdown.preview(ofDraft: edited) == .ready("<h1>Looks good</h1>\n<p>Thanks @octocat, see #12 &amp; `run()`.</p>\n<p>One more thing.</p>"))
        #expect(tab.markdown.preview(ofDraft: draft) != .rendering, "going back to an earlier text is instant")
        #expect(await app.markdown.requests.count == 2)
    }

    @Test func aBlankDraftHasNothingToPreviewAndIsNotSent() async throws {
        let app = try await MarkdownApp()
        let tab = try await app.openFirstPullRequest()

        for blank in ["", "  \n\t\n"] {
            #expect(tab.markdown.preview(ofDraft: blank) == nil)
            await tab.renderDraft(blank)
            #expect(tab.markdown.preview(ofDraft: blank) == nil)
        }
        #expect(await app.markdown.requests.isEmpty)
    }

    @Test func aDraftsFailedPreviewSaysWhyAndCanBeTriedAgain() async throws {
        let app = try await MarkdownApp()
        let tab = try await app.openFirstPullRequest()

        await app.markdown.fail()
        await tab.renderDraft("Ship it")
        guard case let .failed(message)? = tab.markdown.preview(ofDraft: "Ship it") else {
            Issue.record("expected a failure, got \(String(describing: tab.markdown.preview(ofDraft: "Ship it")))")
            return
        }
        #expect(message.contains("500"))

        await app.markdown.recover()
        await tab.renderDraft("Ship it")
        #expect(tab.markdown.preview(ofDraft: "Ship it") == .ready("<p>Ship it</p>"))
    }
}

/// The app's models over the PR fixture and an in-memory store, with markdown rendered by
/// `FakeMarkdown`.
@MainActor
private struct MarkdownApp {
    let github: FakeGitHub
    let details = FakePullRequestDetails()
    let store: PullRequestStore
    let tabs: TabsModel

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        tabs = TabsModel.manuallyTimed(lists: lists, store: store, client: details.client(), notifications: github.notifications())
        await tabs.lists.refresh()
    }

    var markdown: FakeMarkdown { details.markdown }

    /// Makes the first to-review PR a commit writing `files` (nil deletes) in `repo`, branched
    /// from a commit on main writing `base`, and returns it as the lists now have it.
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

    /// The first to-review PR's tab, as for writing on it; no diff is made.
    func openFirstPullRequest() async throws -> PullRequestTab {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        tabs.open(listed)
        return try #require(tabs.tab(id: listed.id))
    }

    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }
}
