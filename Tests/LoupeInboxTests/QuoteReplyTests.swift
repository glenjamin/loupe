@testable import LoupeFakeGitHub
import Foundation
import LoupeInbox
import LoupeModel
import Testing

@MainActor
struct QuoteReplyTests {
    @Test func quotingAThreadsCommentOnTheDiffOpensItsReplyWithTheQuoteAndAddsLaterOnesAfterIt() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        let thread = try #require(tab.thread(threadId))

        #expect(tab.quoteInReply("Why `three`?", to: thread))
        let draft = try #require(tab.threadActivity.replies[threadId])
        #expect(draft.text == "> Why `three`?\n\n")
        #expect(draft.focusRequests == 1, "the composer takes the focus to write after the quote")

        draft.text += "Because of the header row."
        #expect(tab.quoteInReply("three", to: thread))
        #expect(tab.threadActivity.replies[threadId] === draft, "the reply being written, not a new one")
        #expect(draft.text == "> Why `three`?\n\nBecause of the header row.\n\n> three\n\n")
        #expect(draft.focusRequests == 2)
        #expect(tab.threadActivity.replyingInConversation == nil, "the diff's own composer")

        // As github.com's, a quote goes a blank line after what's written, as it is.
        #expect(tab.quoteInReply("again", to: thread))
        #expect(draft.text == "> Why `three`?\n\nBecause of the header row.\n\n> three\n\n\n\n> again\n\n")
        #expect(await app.conversations.repliesReceived.isEmpty, "nothing is sent")
    }

    @Test func aThreadInThePendingReviewTakesNoQuoteOnTheDiff() async throws {
        let (_, tab, _, pendingId) = try await Self.withPendingThread()
        let pending = try #require(tab.thread(pendingId))
        #expect(pending.isPending)

        #expect(!tab.takesQuote(pending))
        #expect(!tab.quoteInReply("Keep this?", to: pending))
        #expect(tab.threadActivity.replies[pendingId] == nil)
    }

    @Test func quotingAThreadsCommentInTheConversationRepliesThereAndAnyOtherCommentGoesToThePR() async throws {
        let (app, tab, threadId, pendingId) = try await Self.withPendingThread()

        tab.quoteInConversation("Why three?", fromThread: threadId)
        #expect(tab.threadActivity.replyingInConversation == threadId, "over the conversation, by the thread")
        #expect(tab.threadActivity.replies[threadId]?.text == "> Why three?\n\n")
        #expect(!tab.conversationComment.isOpen)

        tab.quoteInConversation("Looks good\n\n- one", fromThread: nil)
        let comment = try #require(tab.conversationComment.draft)
        #expect(tab.conversationComment.isOpen)
        #expect(comment.text == "> Looks good\n> \n> - one\n\n", "every line marked, blank ones too")
        #expect(comment.focusRequests == 1)

        tab.conversationComment.close()
        comment.text += "Agreed."
        tab.quoteInConversation("ship it", fromThread: nil)
        #expect(tab.conversationComment.isOpen, "opened again")
        #expect(tab.conversationComment.draft === comment)
        #expect(comment.text == "> Looks good\n> \n> - one\n\nAgreed.\n\n> ship it\n\n")

        // A thread that takes no reply, here one in the viewer's pending review, is quoted on the PR.
        tab.quoteInConversation("Keep this?", fromThread: pendingId)
        #expect(tab.threadActivity.replies[pendingId] == nil)
        #expect(comment.text.hasSuffix("> ship it\n\n\n\n> Keep this?\n\n"))
        #expect(await app.conversations.repliesReceived.isEmpty, "nothing is sent")
    }

    /// A PR open in its tab with someone else's thread, and one in the viewer's pending review.
    private static func withPendingThread() async throws -> (ThreadsApp, PullRequestTab, String, String) {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let threadId = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 11, body: "Why three?")
        let pendingId = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 50, side: "LEFT", pending: true, body: "Keep this?", by: FakeGitHub.viewer)
        return (app, try await app.open(pullRequest), threadId, pendingId)
    }
}
