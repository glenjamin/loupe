import Foundation
import LoupeCore
import LoupeModel
import Testing
import WebKit

struct ConversationHTMLTests {
    @Test func gitHubsHTMLGoesInVerbatimAndEverythingElseIsEscaped() throws {
        let page = try render(conversation)

        #expect(page.contains(#"<p>Adds <code>&lt;Widget&gt;</code> &amp; tests</p>"#), "the description as GitHub rendered it")
        #expect(page.contains(#"<p>Nice, see <a href="https://github.com/o/r/pull/1">#1</a></p>"#))
        #expect(page.contains("<strong>mallory&lt;script&gt;</strong>"))
        #expect(!page.contains("<script>"))
        #expect(page.contains("requested a review from <strong>team&amp;co</strong>"))
        #expect(page.contains(#"<span class="headline">Fix &quot;quotes&quot; &lt;b&gt;</span>"#))
        #expect(!page.contains("javascript:"), "only https links and images")
        #expect(page.contains(#"src="https://avatars.githubusercontent.com/u/1?v=4&amp;s=80""#))
        #expect(!page.contains("{{"), "the template's placeholders are filled")
    }

    @Test func reviewCommentsAreGroupedInTheirThreadsUnderTheirReview() throws {
        let page = try render(conversation)
        let review = try #require(page.range(of: #"<article class="item review">"#))
        let reviewEnd = try #require(page.range(of: "</article>", range: review.upperBound..<page.endIndex))
        let reviewHTML = page[review.lowerBound..<reviewEnd.upperBound]

        #expect(reviewHTML.contains(#"<span class="badge changes-requested">Changes requested</span>"#))
        #expect(reviewHTML.contains("<p>Two things</p>"))
        #expect(reviewHTML.contains("<code>app/widget.go:12</code>"))
        #expect(reviewHTML.contains(#"<tr class="add"><td class="num">11</td><td class="code"><span class="marker">+</span>  <span class="syntax-keyword">return</span> <span class="syntax-keyword">&lt;</span>"#), "the end of the hunk, numbered, highlighted and escaped")
        #expect(reviewHTML.contains("<p>Why nil?</p>"))
        #expect(reviewHTML.contains("<p>Because.</p>"), "a later reply shows in its thread")
        #expect(reviewHTML.contains("<code>README.md:3</code>"), "the original line once outdated")
        #expect(page.components(separatedBy: "<p>Because.</p>").count == 2, "the reply shows once")
    }


    @Test func aThreadOnSeveralLinesShowsThemAllUnderWhichLinesItsOn() throws {
        let snippet = try hunk(in: render(snippetConversation(startLine: 3)))
        #expect(rowNumbers(in: snippet) == [3, 4, 5, 6, 7], "from its first line to its last, as github.com shows")
        let page = try render(snippetConversation(startLine: 3))
        #expect(page.contains(#"<div class="hunk-lines">Comment on lines <span class="add">+3</span> to <span class="add">+7</span></div>"#))
    }

    @Test func aThreadOnOneLineShowsTheLastFewLinesOfItsHunk() throws {
        let page = try render(snippetConversation(startLine: nil))
        #expect(rowNumbers(in: try hunk(in: page)) == [4, 5, 6, 7])
        #expect(!page.contains(#"class="hunk-lines""#), "no range to name")
    }

    @Test func aThreadsSnippetIsHighlightedAsTheDiffIsWithItsRowsAndTabsKept() throws {
        let snippet = try hunk(in: render(snippetConversation(startLine: 3)))
        #expect(snippet.contains(#"<span class="syntax-keyword">func</span>"#))
        #expect(snippet.contains(#"<span class="syntax-comment">// done</span>"#))
        #expect(snippet.contains("<td class=\"code\"><span class=\"marker\">+</span>\t<span class=\"syntax-keyword\">return</span>"), "tabs are left for the stylesheet to size")
        #expect(!snippet.contains("\n"), "nothing between rows to draw as a blank line")
    }


    @Test func resolvedAndOutdatedThreadsAreMarkedAndResolvedOnesStartFolded() throws {
        let page = try render(conversation)
        #expect(page.contains(#"<details class="thread" data-thread-id="t1" open><summary><a class="thread-location" href="loupe-thread://show/t1" title="Show in the diff"><code>app/widget.go:12</code></a><a class="thread-show""#))
        #expect(page.contains(#"<details class="thread resolved outdated" data-thread-id="t2"><summary><a class="thread-location" href="loupe-thread://show/t2" title="Show in the diff"><code>README.md:3</code></a> <span class="badge outdated">Outdated</span> <span class="badge resolved">Resolved</span>"#))
    }

    @Test func eachThreadLinksToItsPlaceInTheDiffAndOffersWhatTheViewerMayDo() throws {
        let page = try render(conversation)
        let links = hrefs(in: page).compactMap(ThreadLink.init(url:))

        #expect(links == [
            ThreadLink(.show, thread: "t1"), ThreadLink(.show, thread: "t1"), ThreadLink(.reply, thread: "t1"), ThreadLink(.resolve, thread: "t1"),
            ThreadLink(.show, thread: "t2"), ThreadLink(.show, thread: "t2"), ThreadLink(.unresolve, thread: "t2"),
        ], "its place and Show in diff, then Reply… and Resolve where allowed; t2 takes no reply")
        #expect(page.contains(#">Show in diff</a>"#))
        #expect(page.contains(#">Reply…</a><a class="thread-resolve" href="loupe-thread://resolve/t1">Resolve conversation</a>"#))
        #expect(page.contains(#">Unresolve conversation</a>"#))
    }

    @Test func commentsReviewsAndThreadCommentsCarryTheirIdsForALinkToLandOn() throws {
        let page = try render(conversation)
        let ids = page.matches(of: /data-comment-id="([^"]+)"/).map { String($0.1) }
        #expect(ids == ["c1", "r1", "rc1", "rc3", "rc4", "rc2"], "in the page's order, each thread's comments inside its review")
        #expect(page.contains(#"<div class="card" data-comment-id="c1">"#))
    }

    @Test func aForcePushOffersToShowItsChangesWhenBothHeadsAreKnown() throws {
        let before = "4cbb2c6d16755ad1fff7442412b242ad6c7a8d33"
        let after = "fa910661c07e29e142c4b38f8ee93a422abfd51a"
        var pushed = conversation
        pushed.items = [
            TimelineItem(id: "fp1", date: now, actor: Participant(login: "octocat", avatarURL: nil), event: .forcePushed(before: before, after: after)),
            TimelineItem(id: "fp2", date: now, actor: Participant(login: "octocat", avatarURL: nil), event: .forcePushed(before: nil, after: after)),
        ]
        let page = try render(pushed)

        #expect(hrefs(in: page).compactMap(ChangesLink.init(url:)) == [ChangesLink(forcePushFrom: before, to: after)], "the second's earlier head is gone, so it has no link")
        #expect(page.contains(#"<a class="event-action" href="loupe-changes://force-push/\#(before)/\#(after)">Show changes</a>"#))
        #expect(page.contains("force-pushed the branch from <code>4cbb2c6</code> to <code>fa91066</code>"))
    }

    @Test func aChangesLinkCarriesOnlyCommitOids() throws {
        let link = try #require(ChangesLink(forcePushFrom: "abc123", to: "def456"))
        #expect(ChangesLink(url: link.url) == link)
        #expect(ChangesLink(forcePushFrom: "abc", to: "not/an/oid") == nil)
        #expect(ChangesLink(url: try #require(URL(string: "loupe-changes://force-push/abc"))) == nil)
        #expect(ChangesLink(url: try #require(URL(string: "loupe-thread://force-push/abc/def"))) == nil)
    }

    @Test func aThreadLinkCarriesAnyThreadId() throws {
        let link = ThreadLink(.reply, thread: "PRRT_kwDO/a+b=")
        #expect(ThreadLink(url: link.url) == link)
        #expect(ThreadLink(url: try #require(URL(string: "https://github.com/o/r/pull/1"))) == nil)
        #expect(ThreadLink(url: try #require(URL(string: "loupe-thread://delete/t1"))) == nil)
    }

    @Test func reactionsShowAsPillsTheViewersMarkedEachTakingItAwayOrAddingIt() throws {
        let page = try render(conversation)
        #expect(page.contains(#"<a class="reaction reacted" href="loupe-reaction://remove/PR_1/THUMBS_UP" title="You and 2 more reacted with +1">👍<span class="count">3</span></a>"#), "the viewer's own, to take away")
        #expect(page.contains(#"<a class="reaction" href="loupe-reaction://add/PR_1/EYES" title="1 person reacted with eyes">👀<span class="count">1</span></a>"#), "someone else's, to add to")
        #expect(page.contains(#"href="loupe-reaction://add/c1/HEART""#), "on a comment")
        #expect(page.contains(#"<a class="reaction reacted" href="loupe-reaction://remove/rc3/ROCKET""#), "on a thread comment")

        let description = try #require(page.range(of: "</p></div>"))
        let firstPicker = try #require(page.range(of: #"<details class="reaction-picker">"#))
        #expect(firstPicker.lowerBound > description.upperBound, "under the description's body")
        #expect(!page.contains("loupe-reaction://add/rc4/"), "none on a comment still pending")
        #expect(!page.contains("loupe-reaction://add/rr1/"), "none on an event")
    }

    @Test func eachCommentOffersAllEightReactionsBehindAQuietFace() throws {
        let page = try render(conversation)
        let links = hrefs(in: page).compactMap(ReactionLink.init(url:))
        let offered = links.filter { $0.subjectId == "PR_1" }
        #expect(offered.map(\.content) == [.thumbsUp, .eyes] + Reaction.allCases, "its pills, then the picker")
        #expect(offered.suffix(8).map(\.action) == [.remove, .add, .add, .add, .add, .add, .add, .add], "the picker takes away what the viewer's made")
        #expect(Set(links.map(\.subjectId)) == ["PR_1", "c1", "r1", "rc1", "rc2", "rc3"], "the description, comments, a review with a summary, and submitted thread comments")
        #expect(page.contains(#"<summary title="Add a reaction"><svg"#))
    }

    @Test func aReactionLinkCarriesAnyIdAndOnlyKnownReactions() throws {
        let link = ReactionLink(.add, .hooray, on: "MDExOlB1bGxSZXF1ZXN0/a+b=")
        #expect(ReactionLink(url: link.url) == link)
        #expect(ReactionLink(url: try #require(URL(string: "loupe-reaction://add/IC_1/SHRUG"))) == nil)
        #expect(ReactionLink(url: try #require(URL(string: "loupe-reaction://toggle/IC_1/HEART"))) == nil)
        #expect(ReactionLink(url: try #require(URL(string: "loupe-thread://show/t1"))) == nil)
    }

    @Test func checksAreListedWithTheirStatusAndLinks() throws {
        let page = try render(conversation)
        #expect(page.contains("Checks <span class=\"muted\">1 failing</span>"))
        #expect(page.contains(#"<li class="check success"><span class="status">✓</span><a href="https://ci.example.com/1">ci/build</a> <span class="muted">Passed &amp; done</span></li>"#))
        #expect(page.contains(#"<li class="check failure"><span class="status">✗</span>codecov/patch</li>"#), "no link for a URL that isn't https")
    }

    @Test func thePageEndsWithAWayToCommentOnThePullRequest() throws {
        let page = try render(conversation)
        #expect(hrefs(in: page).last.flatMap(CommentLink.init(url:)) == CommentLink(), "the last link on the page")
        let link = try #require(page.range(of: #"<a href="loupe-comment://new" data-new-comment>Add a comment…</a>"#))
        let lastItem = try #require(page.range(of: "<p>Two things</p>"))
        let checks = try #require(page.range(of: #"<section class="checks">"#))
        #expect(link.lowerBound > lastItem.upperBound && link.lowerBound > checks.upperBound, "after the timeline and its checks, as on github.com")
        #expect(CommentLink(url: try #require(URL(string: "loupe-thread://new"))) == nil)
    }

    @Test func whatTheViewerMayEditOffersAnEditByItsHeader() throws {
        #expect(editLinks(in: try render(conversation)).isEmpty, "nothing GitHub doesn't let them edit")
        var editable = conversation
        editable.items[0].viewerCanUpdate = true
        editable.items[3].viewerCanUpdate = true
        for index in editable.threads[0].comments.indices.dropFirst() { editable.threads[0].comments[index].viewerCanUpdate = true }
        let page = try render(editable)

        #expect(editLinks(in: page) == ["c1", "r1", "rc3", "rc4"], "a comment, a review's summary, and thread comments, pending or not")
        #expect(page.contains(#"<header><a class="comment-edit" href="loupe-comment://edit/c1" data-edit-comment="c1">Edit</a><strong>mallory&lt;script&gt;</strong> commented"#))
    }

    @Test func whatTheViewerMayDeleteOffersADeletionBesideItsEdit() throws {
        var deletable = conversation
        deletable.items[0].viewerCanDelete = true
        deletable.items[0].viewerCanUpdate = true
        deletable.items[3].viewerCanDelete = true
        deletable.threads[0].comments[1].viewerCanDelete = true
        let page = try render(deletable)

        #expect(deletionLinks(in: page) == ["c1", "rc3", "rc4"], "comments and thread comments, the viewer's pending one too, but not a review")
        #expect(page.contains(#"<header><a class="comment-delete" href="loupe-comment://delete/c1">Delete</a><a class="comment-edit" href="loupe-comment://edit/c1" data-edit-comment="c1">Edit</a><strong>"#))
    }

    @Test func anEditOnItsWayShowsAsSavingWithNoEditOffered() throws {
        var saving = conversation
        saving.items[0].viewerCanUpdate = true
        saving.items[0].isSaving = true
        saving.items[0].event = .comment(bodyHTML: "<p>Nicer, see #1</p>", isMinimized: false)
        saving.threads[0].comments[1].viewerCanUpdate = true
        saving.threads[0].comments[1].isSaving = true
        let page = try render(saving)
        #expect(page.contains(#"<strong>mallory&lt;script&gt;</strong> commented <span class="muted saving">Saving…</span></header><div class="body"><p>Nicer, see #1</p>"#))
        #expect(page.contains(#"<strong>octocat</strong> <span class="muted saving">Saving…</span></header><div class="body"><p>Because.</p>"#))
        #expect(!page.contains("loupe-comment://edit"))
    }

    @Test func anEditLinkCarriesAnyId() throws {
        let link = CommentLink(editing: "IC_kwDO/a+b=")
        #expect(CommentLink(url: link.url) == link)
        #expect(CommentLink(url: try #require(URL(string: "loupe-comment://edit/"))) == nil)
        let deletion = CommentLink(deleting: "IC_kwDO/a+b=")
        #expect(CommentLink(url: deletion.url) == deletion && deletion != link)
        #expect(CommentLink(url: try #require(URL(string: "loupe-comment://delete/"))) == nil)
        #expect(CommentLink(url: try #require(URL(string: "loupe-comment://hide/c1"))) == nil)
    }

    @Test func everyTimeOnThePageCarriesWhenItWasAndShowsTheFullDateOnHover() throws {
        let events: [TimelineEvent] = [.forcePushed(before: nil, after: nil), .merged(commit: nil, into: "main"), .closed, .reopened, .readyForReview]
        var everything = conversation
        everything.items += events.enumerated().map { index, event in
            TimelineItem(id: "e\(index)", date: now.addingTimeInterval(Double(index * 1000 - 20_000)), actor: nil, event: event)
        }
        let page = try render(everything)
        let times = page.matches(of: /<time datetime="([^"]+)" title="([^"]+)">/).map { (String($0.1), String($0.2)) }

        let threadComments = everything.threads.flatMap(\.comments).map(\.createdAt)
        let dates = [everything.createdAt] + everything.items.prefix(4).map(\.date) + threadComments + everything.items.suffix(events.count).map(\.date)
        #expect(times.map(\.0) == dates.map { $0.formatted(.iso8601) }, "the description, comments, commits, review, each thread comment and every event, in order")
        #expect(times.map(\.1) == dates.map { $0.formatted(date: .complete, time: .shortened) })
    }

    @MainActor
    @Test func aPagesTimesAreRewordedInPlaceAsTimePassesLeavingTheRestBe() async throws {
        let now = Date.now
        var recent = conversation
        // Years ago, so two hours on can't cross into another day and change its words.
        recent.createdAt = now.addingTimeInterval(-900 * 86_400)
        recent.items = [TimelineItem(id: "c1", date: now.addingTimeInterval(-30_000), actor: nil, event: .comment(bodyHTML: "<p>Hi</p>", isMinimized: false))]
        recent.threads = []
        let (template, stylesheet) = try templates()
        let page = ConversationHTML.page(recent, template: template, stylesheet: stylesheet, now: now)
        let script = try #require(RelativeTimes.functions())
        let body = script + """

            document.documentElement.innerHTML = page;
            const before = Array.from(document.querySelectorAll('time'), time => time.textContent);
            const changed = moveClock(2 * 60 * 60 * 1000);
            return { before, changed, after: Array.from(document.querySelectorAll('time'), time => time.textContent) };
            """
        let found = try await WKWebView().callAsyncJavaScript(body, arguments: ["page": page], in: nil, contentWorld: .defaultClient)
        let result = try #require(found as? [String: Any])

        let opened = recent.createdAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "en_US")))
        #expect(result["before"] as? [String] == [opened, "8 hours ago"], "as Swift wrote them")
        #expect(result["after"] as? [String] == [opened, "10 hours ago"], "two hours on")
        #expect(result["changed"] as? Int == 1, "only the time whose words moved on is touched")
    }

    @Test func aCommentOnItsWayShowsAsSendingWithNothingToReactTo() throws {
        var sending = conversation
        sending.items.append(TimelineItem(id: "loupe-sending-1", date: now, actor: Participant(login: "viewer", avatarURL: nil), event: .comment(bodyHTML: "<p>On its way</p>", isMinimized: false), isSending: true))
        let page = try render(sending)
        let card = try #require(page.range(of: "<strong>viewer</strong>").map { page[$0.lowerBound...] })
        #expect(card.hasPrefix(#"<strong>viewer</strong> commented <span class="muted sending">Sending…</span>"#))
        #expect(!hrefs(in: page).compactMap(ReactionLink.init(url:)).contains { $0.subjectId == "loupe-sending-1" })
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let conversation = Conversation(
    id: "PR_1",
    author: Participant(login: "octocat", avatarURL: "https://avatars.githubusercontent.com/u/1?v=4"),
    createdAt: now.addingTimeInterval(-86_400),
    bodyHTML: "<p>Adds <code>&lt;Widget&gt;</code> &amp; tests</p>",
    reactions: [ReactionGroup(content: .thumbsUp, count: 3, viewerHasReacted: true), ReactionGroup(content: .eyes, count: 1, viewerHasReacted: false)],
    items: [
        TimelineItem(id: "c1", date: now.addingTimeInterval(-80_000), actor: Participant(login: "mallory<script>", avatarURL: "javascript:alert(1)"), event: .comment(bodyHTML: #"<p>Nice, see <a href="https://github.com/o/r/pull/1">#1</a></p>"#, isMinimized: false), reactions: [ReactionGroup(content: .heart, count: 1, viewerHasReacted: false)]),
        TimelineItem(id: "rr1", date: now.addingTimeInterval(-70_000), actor: nil, event: .reviewRequested(reviewer: "team&co")),
        TimelineItem(id: "commit1", date: now.addingTimeInterval(-60_000), actor: nil, event: .commit(oid: "0123456789abcdef", headline: #"Fix "quotes" <b>"#)),
        TimelineItem(id: "r1", date: now.addingTimeInterval(-50_000), actor: Participant(login: "reviewer", avatarURL: nil), event: .review(state: .changesRequested, bodyHTML: "<p>Two things</p>", comments: [
            ReviewComment(id: "rc1", bodyHTML: "<p>Why nil?</p>", path: "app/widget.go", line: 12, originalLine: 12, diffHunk: "@@ -10,2 +10,3 @@ func Widget() {\n   x := 1\n+  return <nil>", isOutdated: false, isMinimized: false, replyTo: nil),
            ReviewComment(id: "rc2", bodyHTML: "<p>Typo</p>", path: "README.md", line: nil, originalLine: 3, diffHunk: "@@ -1,3 +1,3 @@\n-teh\n+the", isOutdated: true, isMinimized: false, replyTo: nil),
        ])),
    ],
    threads: [
        ReviewThread(id: "t1", isResolved: false, isOutdated: false, path: "app/widget.go", line: 12, viewerCanReply: true, viewerCanResolve: true, comments: [
            ThreadComment(id: "rc1", author: Participant(login: "reviewer", avatarURL: nil), createdAt: now.addingTimeInterval(-50_000), bodyHTML: "<p>Why nil?</p>", isMinimized: false),
            ThreadComment(id: "rc3", author: Participant(login: "octocat", avatarURL: nil), createdAt: now.addingTimeInterval(-40_000), bodyHTML: "<p>Because.</p>", isMinimized: false, reactions: [ReactionGroup(content: .rocket, count: 1, viewerHasReacted: true)]),
            ThreadComment(id: "rc4", author: Participant(login: "octocat", avatarURL: nil), createdAt: now.addingTimeInterval(-30_000), bodyHTML: "<p>Pending thought</p>", isMinimized: false, isPending: true),
        ]),
        ReviewThread(id: "t2", isResolved: true, isOutdated: true, path: "README.md", line: nil, viewerCanUnresolve: true, comments: [
            ThreadComment(id: "rc2", author: Participant(login: "reviewer", avatarURL: nil), createdAt: now.addingTimeInterval(-50_000), bodyHTML: "<p>Typo</p>", isMinimized: false),
        ]),
    ],
    checks: [
        CheckContext(name: "ci/build", status: .success, description: "Passed & done", url: "https://ci.example.com/1"),
        CheckContext(name: "codecov/patch", status: .failure, description: nil, url: "http://insecure.example.com"),
    ]
)


/// A review on a Go hunk whose last line, 7, is commented on, from `startLine` when on several.
private func snippetConversation(startLine: Int?) -> Conversation {
    let diffHunk = "@@ -1,1 +1,7 @@ package main\n import \"fmt\"\n+\n+func add(a, b int) int {\n+\treturn a + b\n+}\n+\n+// done"
    let author = Participant(login: "reviewer", avatarURL: nil)
    return Conversation(
        id: "PR_2", author: author, createdAt: now, bodyHTML: "", reactions: [],
        items: [
            TimelineItem(id: "r1", date: now, actor: author, event: .review(state: .commented, bodyHTML: "", comments: [
                ReviewComment(id: "rc1", bodyHTML: "<p>Nice</p>", path: "main.go", line: 7, originalLine: 7, diffHunk: diffHunk, isOutdated: false, isMinimized: false, replyTo: nil),
            ])),
        ],
        threads: [
            ReviewThread(id: "t1", isResolved: false, isOutdated: false, path: "main.go", line: 7, startLine: startLine, originalLine: 7, originalStartLine: startLine, diffHunk: diffHunk, comments: [
                ThreadComment(id: "rc1", author: author, createdAt: now, bodyHTML: "<p>Nice</p>", isMinimized: false),
            ]),
        ],
        checks: []
    )
}

private func render(_ conversation: Conversation) throws -> String {
    let (template, stylesheet) = try templates()
    return ConversationHTML.page(conversation, template: template, stylesheet: stylesheet, now: now)
}

/// The app's own template and stylesheet.
private func templates() throws -> (String, String) {
    let resources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/Loupe/Resources")
    return (
        try String(contentsOf: resources.appending(path: "conversation.html"), encoding: .utf8),
        try String(contentsOf: resources.appending(path: "conversation.css"), encoding: .utf8)
    )
}

/// Every link's target in the page, in order.
private func hrefs(in page: String) -> [URL] {
    page.matches(of: /href="([^"]*)"/).compactMap { URL(string: String($0.1)) }
}

/// The ids of what the page offers to edit, in order.
private func editLinks(in page: String) -> [String] {
    hrefs(in: page).compactMap(CommentLink.init(url:)).compactMap { link in
        if case let .edit(id) = link.target { id } else { nil }
    }
}

/// The ids of what the page offers to delete, in order.
private func deletionLinks(in page: String) -> [String] {
    hrefs(in: page).compactMap(CommentLink.init(url:)).compactMap { link in
        if case let .delete(id) = link.target { id } else { nil }
    }
}


/// The page's first thread snippet.
private func hunk(in page: String) throws -> Substring {
    let start = try #require(page.range(of: #"<table class="hunk">"#))
    let end = try #require(page.range(of: "</table>", range: start.upperBound..<page.endIndex))
    return page[start.lowerBound..<end.upperBound]
}

/// The line numbers down a snippet's rows.
private func rowNumbers(in snippet: Substring) -> [Int] {
    snippet.matches(of: /<td class="num">(\d+)<\/td>/).compactMap { Int($0.1) }
}
