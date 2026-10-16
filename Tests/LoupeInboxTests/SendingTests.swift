import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import Testing

/// The viewer's comments and changes to threads and reviews show at once, before GitHub
/// answers, and take GitHub's copy, or go again, once it does.
@MainActor
struct SendingTests {
    @Test func aReplyShowsAtOnceAndGitHubsCopyTakesItsPlace() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        await app.conversations.hold(.reply)
        let thread = try #require(tab.thread(threadId))
        tab.startReply(to: thread)
        try #require(tab.threadActivity.replies[threadId]).text = "On it <soon> & then"

        let sending = Task { await tab.sendReply(to: thread) }
        await app.conversations.arrival(of: .reply)

        #expect(tab.threadActivity.replies[threadId] == nil, "closed as it's sent")
        let shown = try #require(tab.thread(threadId)?.comments.last)
        #expect(shown.isSending)
        #expect(shown.author?.login == FakeGitHub.viewer)
        #expect(shown.bodyHTML == "<p>On it &lt;soon&gt; &amp; then</p>", "as plain text until GitHub renders it")
        #expect(try #require(tab.threadsOn("app.go").anchored.first { $0.line == 11 }?.threads.first).comments.last == shown, "on the diff too")
        let stored = try #require(try app.store.conversation(of: tab.id)?.threads.first { $0.id == threadId }?.comments.last)
        #expect(stored.id == shown.id && stored.isSending && stored.bodyHTML == shown.bodyHTML, "stored as it's shown")

        await app.conversations.release(.reply)
        await sending.value

        let replied = try #require(tab.thread(threadId))
        #expect(replied.comments.count == 2, "the fetch after doesn't add it again")
        let posted = try #require(replied.comments.last)
        #expect(!posted.isSending)
        #expect(posted.bodyHTML == "<p dir=\"auto\">On it &lt;soon&gt; &amp; then</p>", "GitHub's rendering")
        #expect(posted.databaseId != nil && posted.id.hasPrefix("PRRC_"))
        #expect(try app.store.conversation(of: tab.id)?.threads == tab.conversation?.threads)
    }

    @Test func aRefusedReplyGoesAndItsDraftOpensAgainWhereItWasWritten() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        await app.conversations.refuseThreadChanges()
        await app.conversations.hold(.reply)
        tab.section = .conversation
        await tab.follow(ThreadLink(.reply, thread: threadId))
        let draft = try #require(tab.threadActivity.replies[threadId])
        draft.text = "A careful answer"

        let sending = Task { await tab.sendReply(to: try #require(tab.thread(threadId))) }
        await app.conversations.arrival(of: .reply)
        #expect(tab.thread(threadId)?.comments.last?.isSending == true)
        #expect(tab.threadActivity.replyingInConversation == nil, "put away as it's sent")

        await app.conversations.release(.reply)
        try await sending.value

        #expect(tab.thread(threadId)?.comments.count == 1, "taken away")
        #expect(tab.threadActivity.replies[threadId] === draft)
        #expect(draft.text == "A careful answer")
        #expect(tab.threadActivity.replyingInConversation == threadId, "open again by the thread")
        #expect(tab.threadActivity.errors[threadId]?.contains("Resource not accessible") == true)
        #expect(try app.store.conversation(of: tab.id)?.threads == tab.conversation?.threads, "gone from the store too")
    }

    @Test func aNewCommentShowsOnItsLineAndInTheConversationThenTakesGitHubsThread() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let threadCount = try #require(tab.conversation?.threads.count)
        await app.conversations.hold(.comment)
        tab.startComment(at: DiffAnchor(path: "app.go", side: .left, line: 50))
        try #require(tab.threadActivity.newComment?.draft).text = "Is anything still using this?"

        let sending = Task { await tab.sendComment() }
        await app.conversations.arrival(of: .comment)

        #expect(tab.threadActivity.newComment == nil)
        let shown = try #require(try tab.threadsOn("app.go").anchored.first { $0.side == .left && $0.line == 50 }?.threads.first)
        #expect(shown.comments.map(\.isSending) == [true])
        #expect(shown.diffHunk.hasSuffix("\n-50 line"), "ending on its line, as GitHub keeps it")
        let page = conversationPage(tab)
        let card = try #require(section(of: page, from: #"data-thread-id="\#(shown.id)""#))
        #expect(card.contains("Is anything still using this?") && card.contains("Sending…"))
        #expect(card.contains("50 line"), "its line of code")

        await app.conversations.release(.comment)
        await sending.value

        let threads = try #require(try tab.threadsOn("app.go").anchored.first { $0.side == .left && $0.line == 50 }?.threads)
        #expect(threads.count == 1, "GitHub's thread in its place, not beside it")
        #expect(threads.first?.comments.map(\.isSending) == [false])
        #expect(threads.first?.id.hasPrefix("PRRT_") == true)
        #expect(tab.conversation?.threads.count == threadCount + 1)
        #expect(!conversationPage(tab).contains("Sending…"))
    }

    @Test func aRefusedNewCommentGoesAndItsDraftOpensAgain() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        await app.conversations.refuseThreadChanges()
        await app.conversations.hold(.comment)
        let anchor = DiffAnchor(path: "app.go", side: .right, line: 10)
        tab.startComment(at: anchor)
        let draft = try #require(tab.threadActivity.newComment?.draft)
        draft.text = "Rename this?"

        let sending = Task { await tab.sendComment() }
        await app.conversations.arrival(of: .comment)
        #expect(tab.unresolvedThreadCount(of: "app.go") == 2, "shown at once")

        await app.conversations.release(.comment)
        await sending.value

        #expect(tab.unresolvedThreadCount(of: "app.go") == 1)
        #expect(tab.threadActivity.newComment?.anchor == anchor)
        #expect(tab.threadActivity.newComment?.draft === draft && draft.text == "Rename this?")
        #expect(tab.threadActivity.newCommentError?.contains("Resource not accessible") == true)
        #expect(!conversationPage(tab).contains("Rename this?"))
    }

    @Test func aConversationFetchedBeforeGitHubHadTheReplyDoesntTakeItAwayOrDoubleIt() async throws {
        let app = try await ThreadsApp()
        let pullRequest = app.tabs.lists.pullRequests(in: .toReview)[0]
        try await app.conversations.add(pullRequest.id, number: pullRequest.number)
        let tab = try await app.open(pullRequest)
        let thread = try #require(tab.conversation?.threads.first { $0.viewerCanReply })
        await app.conversations.hold(.reply)
        tab.startReply(to: thread)
        try #require(tab.threadActivity.replies[thread.id]).text = "Fixed now"
        let sending = Task { await tab.sendReply(to: thread) }
        await app.conversations.arrival(of: .reply)

        // The conversation is asked for before GitHub has the reply, and lands after it does.
        await app.conversations.hold(.conversation)
        let fetching = Task { await tab.retry() }
        await app.conversations.arrival(of: .conversation)
        await app.conversations.release(.reply)
        await sending.value
        let posted = try #require(tab.reviewThread(thread.id)?.comments.last)
        #expect(!posted.isSending)
        await app.conversations.release(.conversation)
        await fetching.value

        let comments = try #require(tab.reviewThread(thread.id)?.comments)
        #expect(comments.last == posted, "kept, as GitHub answered for it")
        #expect(comments.count(where: { $0.bodyHTML.contains("Fixed now") }) == 1)
        let page = conversationPage(tab)
        let card = try #require(section(of: page, from: #"data-thread-id="\#(thread.id)""#))
        #expect(card.contains("Fixed now"), "in its thread on the page")
        #expect(page.components(separatedBy: "Fixed now").count == 2, "once")
    }

    @Test func resolvingShowsAtOnceAndARefusalPutsItBack() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        await app.conversations.hold(.resolve)
        let resolving = Task { await tab.setResolved(true, thread: try #require(tab.thread(threadId))) }
        await app.conversations.arrival(of: .resolve)
        let shown = try #require(tab.thread(threadId))
        #expect(shown.isResolved && shown.viewerCanUnresolve && shown.resolvedBy == FakeGitHub.viewer)
        #expect(try app.store.conversation(of: tab.id)?.threads.first { $0.id == threadId }?.isResolved == true)
        await app.conversations.release(.resolve)
        try await resolving.value
        #expect(tab.thread(threadId)?.isResolved == true)

        await app.conversations.refuseThreadChanges()
        await app.conversations.hold(.resolve)
        let unresolving = Task { await tab.setResolved(false, thread: try #require(tab.thread(threadId))) }
        await app.conversations.arrival(of: .resolve)
        #expect(tab.thread(threadId)?.isResolved == false, "unresolved at once")
        await app.conversations.release(.resolve)
        try await unresolving.value
        #expect(tab.thread(threadId)?.isResolved == true, "put back")
        #expect(tab.threadActivity.errors[threadId]?.contains("Couldn't unresolve") == true)
        #expect(try app.store.conversation(of: tab.id)?.threads == tab.conversation?.threads)
    }

    @Test func aReviewCommentShowsPendingAtOnceAndASecondWaitsForTheReviewTheFirstStarts() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let threadCount = try #require(tab.conversation?.threads.count)
        await app.conversations.hold(.addToReview)
        let first = try write("Is anything still using this?", at: DiffAnchor(path: "app.go", side: .left, line: 50), on: tab)
        let starting = Task { await tab.sendReviewComment() }
        await app.conversations.arrival(of: .addToReview)

        #expect(tab.threadActivity.newComment == nil)
        #expect(tab.pendingComments.map(\.comment.isSending) == [true])
        #expect(tab.pendingComments.first?.comment.bodyHTML == "<p>\(first)</p>")
        #expect(tab.pendingComments.first?.commentedCode == "50 line", "its line of code, in the pending list")

        let second = try write("And this name?", at: DiffAnchor(path: "app.go", side: .right, line: 12), on: tab)
        let joining = Task { await tab.sendReviewComment() }
        await Task.yield()
        #expect(tab.pendingComments.count == 2, "both shown while the review starts")

        await app.conversations.release(.addToReview)
        await starting.value
        await joining.value

        let reviewId = try #require(await app.conversations.pendingReviewId(of: tab.id))
        #expect(await app.conversations.reviewMutationsReceived.dropFirst().first == .addThread(reviewId: reviewId, .init(path: "app.go", line: 12, side: "RIGHT", body: second)), "added to the review, not starting another")
        #expect(tab.pendingReview == PendingReview(id: reviewId, body: "", commentCount: 2))
        #expect(tab.pendingComments.map(\.comment.isSending) == [false, false])
        #expect(tab.conversation?.threads.count == threadCount + 2)
    }

    @Test func deletingAPendingCommentTakesItAwayAtOnceAndARefusalBringsItBack() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        try await addToReview("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        try await addToReview("And here", at: DiffAnchor(path: "app.go", side: .right, line: 12), on: tab)
        let thread = try #require(tab.placedThreads.first { $0.isPending && $0.line == 11 })
        await app.conversations.refuseThreadChanges()
        await app.conversations.hold(.deleteComment)

        let deleting = Task { await tab.deletePendingComment(try #require(thread.comments.first), in: thread) }
        await app.conversations.arrival(of: .deleteComment)
        #expect(tab.reviewThread(thread.id) == nil, "gone at once")
        #expect(tab.pendingReview?.commentCount == 1)
        #expect(!conversationPage(tab).contains("Hmm"))

        await app.conversations.release(.deleteComment)
        try await deleting.value
        #expect(tab.reviewThread(thread.id) == thread, "back as it was")
        #expect(tab.pendingReview?.commentCount == 2)
        #expect(conversationPage(tab).contains("Hmm"))
    }

    @Test func discardingTakesTheReviewAwayAtOnceAndARefusalBringsItAndTheSummaryBack() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        let others = tab.conversation?.threads.map(\.id)
        try await addToReview("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        let before = tab.conversation
        tab.reviewDraft.body = "Half-written"
        await app.conversations.refuseThreadChanges()
        await app.conversations.hold(.discard)

        let discarding = Task { await tab.discardReview() }
        await app.conversations.arrival(of: .discard)
        #expect(tab.pendingReview == nil)
        #expect(tab.conversation?.threads.map(\.id) == others, "its thread gone with it")
        #expect(tab.reviewDraft.body.isEmpty)

        await app.conversations.release(.discard)
        await discarding.value
        #expect(tab.conversation == before, "back as it was")
        #expect(tab.reviewDraft.body == "Half-written")
        #expect(tab.reviewDraft.error?.contains("Couldn't discard") == true)
    }

    @Test func aSubmittedReviewShowsInTheConversationAtOnceAndTakesGitHubsCopy() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        try await addToReview("Nit: rename", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        let reviewId = try #require(tab.pendingReview?.id)
        tab.reviewDraft.body = "Looks good"
        await app.conversations.hold(.submit)

        let submitting = Task { await tab.submitReview(as: .approve) }
        await app.conversations.arrival(of: .submit)

        #expect(tab.pendingReview == nil)
        #expect(tab.conversation?.threads.allSatisfy { !$0.isPending } == true, "its comments submitted")
        let shown = try #require(tab.conversation?.items.first { $0.id == reviewId })
        #expect(shown.isSending)
        #expect(shown.event == .review(state: .approved, bodyHTML: "<p>Looks good</p>", comments: review(shown)?.comments ?? []))
        #expect(review(shown)?.comments.count == 1, "holding the thread it started")
        let page = conversationPage(tab)
        #expect(page.contains("approved these changes") && page.contains("Sending…"))
        #expect(tab.reviewDraft.body.isEmpty)

        await app.conversations.release(.submit)
        await submitting.value

        let reviews = tab.conversation?.items.filter { $0.id == reviewId } ?? []
        #expect(reviews.count == 1, "GitHub's copy in its place")
        #expect(reviews.first?.isSending == false)
        #expect(reviews.first.flatMap(review)?.bodyHTML == "<p dir=\"auto\">Looks good</p>")
        #expect(!conversationPage(tab).contains("Sending…"))
    }

    @Test func aRefusedSubmissionPutsThePendingReviewAndTheSummaryBack() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        try await addToReview("Hmm", at: DiffAnchor(path: "app.go", side: .right, line: 11), on: tab)
        let before = tab.conversation
        tab.reviewDraft.body = "Looks good"
        await app.conversations.refuseThreadChanges()
        await app.conversations.hold(.submit)

        let submitting = Task { await tab.submitReview(as: .requestChanges) }
        await app.conversations.arrival(of: .submit)
        #expect(tab.pendingReview == nil)

        await app.conversations.release(.submit)
        await submitting.value
        #expect(tab.conversation == before)
        #expect(tab.reviewDraft.body == "Looks good")
        #expect(tab.reviewDraft.error?.contains("Couldn't submit") == true)
    }

    /// Opens a comment under `anchor` with `text` typed, and returns the text.
    private func write(_ text: String, at anchor: DiffAnchor, on tab: PullRequestTab) throws -> String {
        tab.startComment(at: anchor)
        try #require(tab.threadActivity.newComment?.draft).text = text
        return text
    }

    private func addToReview(_ text: String, at anchor: DiffAnchor, on tab: PullRequestTab) async throws {
        _ = try write(text, at: anchor, on: tab)
        await tab.sendReviewComment()
        #expect(tab.threadActivity.newCommentError == nil)
    }

    private func conversationPage(_ tab: PullRequestTab) -> String {
        ConversationHTML.page(tab.conversation, template: "{{content}}", stylesheet: "")
    }

    /// The page from `marker` to the next thread, or its end.
    private func section(of page: String, from marker: String) -> String? {
        guard let start = page.range(of: marker) else { return nil }
        let end = page.range(of: "data-thread-id=", range: start.upperBound..<page.endIndex)?.lowerBound ?? page.endIndex
        return String(page[start.lowerBound..<end])
    }

    private func review(_ item: TimelineItem) -> (bodyHTML: String, comments: [ReviewComment])? {
        if case let .review(_, bodyHTML, comments) = item.event { (bodyHTML, comments) } else { nil }
    }
}
