import Foundation
import LoupeCore
import LoupeModel
import Testing

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
        #expect(reviewHTML.contains(#"<span class="add">+  return &lt;nil&gt;</span>"#), "the end of the hunk, escaped")
        #expect(reviewHTML.contains("<p>Why nil?</p>"))
        #expect(reviewHTML.contains("<p>Because.</p>"), "a later reply shows in its thread")
        #expect(reviewHTML.contains("<code>README.md:3</code>"), "the original line once outdated")
        #expect(page.components(separatedBy: "<p>Because.</p>").count == 2, "the reply shows once")
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
