@testable import LoupeFakeGitHub
import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import Testing

/// The viewer's comments, thread comments and review summaries are edited from GitHub's
/// markdown, show the edit at once, and take GitHub's rendering, or the old body back, once it
/// answers. Their comments are deleted likewise: gone at once, and back if GitHub refuses.
@MainActor
struct CommentEditTests {
    @Test func aPendingCommentIsEditedFromGitHubsMarkdownAndShowsSavingThenGitHubsCopy() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        tab.startComment(at: DiffAnchor(path: "app.go", side: .right, line: 11))
        try #require(tab.threadActivity.newComment?.draft).text = "Is three *right*?"
        await tab.sendReviewComment()
        let thread = try #require(tab.placedThreads.first { $0.isPending })
        let comment = try #require(thread.comments.first)
        #expect(tab.canEdit(comment.id))

        await tab.startEdit(of: comment.id)
        let edit = try #require(tab.commentEdits.edits[comment.id])
        #expect(edit.phase == .editing)
        #expect(edit.draft.text == "Is three *right*?", "its markdown, not the rendering")
        #expect(!edit.draft.canSend, "nothing to save while unchanged")
        edit.draft.text = " \n"
        await tab.saveEdit(of: comment.id)
        #expect(await app.conversations.editsReceived.isEmpty, "nothing is saved empty")

        edit.draft.text = "Are three <right>?"
        await app.conversations.hold(.edit)
        let saving = Task { await tab.saveEdit(of: comment.id) }
        await app.conversations.arrival(of: .edit)

        #expect(tab.commentEdits.edits[comment.id] == nil, "closed as it's saved")
        let shown = try #require(tab.reviewThread(thread.id)?.comments.first)
        #expect(shown.isSaving && shown.bodyHTML == "<p>Are three &lt;right&gt;?</p>", "as plain text until GitHub renders it")
        #expect(tab.placedThreads.first { $0.id == thread.id }?.comments.first == shown, "on the diff too")
        #expect(!tab.canEdit(comment.id), "not again while it's saving")
        #expect(try app.store.conversation(of: tab.id)?.threads == tab.conversation?.threads, "stored as it's shown")

        await app.conversations.release(.edit)
        await saving.value

        #expect(await app.conversations.editsReceived == [.init(mutation: "updatePullRequestReviewComment", id: comment.id, body: "Are three <right>?")])
        let saved = try #require(tab.reviewThread(thread.id)?.comments.first)
        #expect(!saved.isSaving && saved.isPending)
        #expect(saved.bodyHTML == "<p dir=\"auto\">Are three &lt;right&gt;?</p>", "GitHub's rendering")
        #expect(tab.canEdit(comment.id))
        #expect(await app.conversations.markdown(of: comment.id) == "Are three <right>?")
        #expect(try app.store.conversation(of: tab.id)?.threads == tab.conversation?.threads)
    }

    @Test func aCommentOnThePullRequestIsEditedByItsLinkInTheConversation() async throws {
        let app = try await ThreadsApp()
        let pullRequest = app.tabs.lists.pullRequests(in: .toReview)[0]
        try await app.conversations.add(pullRequest.id, number: pullRequest.number)
        let commentId = await app.conversations.comment("<p dir=\"auto\">Looks <em>fine</em></p>", on: pullRequest.id, by: FakeGitHub.viewer, markdown: "Looks *fine*\r\nto me")
        let tab = try await app.open(pullRequest)
        #expect(try conversationPage(tab).contains(CommentLink(editing: commentId).url.absoluteString))

        await tab.follow(CommentLink(editing: commentId))
        #expect(tab.commentEdits.editingInConversation == commentId)
        let edit = try #require(tab.commentEdits.edits[commentId])
        #expect(edit.draft.text == "Looks *fine*\nto me", "with the editor's line endings, so it isn't counted as changed")
        #expect(!edit.draft.hasChanges)
        edit.draft.text = "Looks *great*"

        await app.conversations.hold(.edit)
        let saving = Task { await tab.saveEdit(of: commentId) }
        await app.conversations.arrival(of: .edit)
        #expect(tab.commentEdits.editingInConversation == nil, "put away as it's saved")
        let page = try conversationPage(tab)
        #expect(page.contains(#"<span class="muted saving">Saving…</span></header><div class="body"><p>Looks *great*</p>"#))
        #expect(!page.contains(CommentLink(editing: commentId).url.absoluteString))

        await app.conversations.release(.edit)
        await saving.value
        #expect(await app.conversations.editsReceived == [.init(mutation: "updateIssueComment", id: commentId, body: "Looks *great*")])
        let item = try #require(tab.conversation?.items.first { $0.id == commentId })
        #expect(!item.isSaving && item.viewerCanUpdate)
        #expect(item.event == .comment(bodyHTML: "<p dir=\"auto\">Looks *great*</p>", isMinimized: false))
        #expect(try app.store.conversation(of: tab.id)?.items == tab.conversation?.items)
    }

    @Test func aReviewsSummaryIsEditedLikewise() async throws {
        let (app, tab) = try await openConversation()
        let reviewId = "PRR_kwDODst66c8AAAABSQ7MWA"
        #expect(tab.canEdit(reviewId), "the viewer's own submitted review")

        await tab.follow(CommentLink(editing: reviewId))
        let edit = try #require(tab.commentEdits.edits[reviewId])
        #expect(edit.draft.text.hasPrefix("if/when FilterSQL is used"))
        edit.draft.text = "Approved, with one question"
        await tab.saveEdit(of: reviewId)

        #expect(await app.conversations.editsReceived == [.init(mutation: "updatePullRequestReview", id: reviewId, body: "Approved, with one question")])
        let review = try #require(tab.conversation?.items.first { $0.id == reviewId })
        guard case let .review(state, bodyHTML, _) = review.event else { Issue.record("not a review"); return }
        #expect(state == .approved && bodyHTML == "<p dir=\"auto\">Approved, with one question</p>")
        #expect(!review.isSaving)
    }

    @Test func aRefusedEditPutsTheOldBodyBackAndOpensTheDraftAgain() async throws {
        let (app, tab) = try await openConversation()
        let reviewId = "PRR_kwDODst66c8AAAABSQ7MWA"
        let before = tab.conversation
        await app.conversations.refuseCommentEdits()
        await tab.follow(CommentLink(editing: reviewId))
        let edit = try #require(tab.commentEdits.edits[reviewId])
        edit.draft.text = "A better summary"

        await app.conversations.hold(.edit)
        let saving = Task { await tab.saveEdit(of: reviewId) }
        await app.conversations.arrival(of: .edit)
        #expect(tab.conversation?.items.first { $0.id == reviewId }?.isSaving == true)

        await app.conversations.release(.edit)
        await saving.value
        #expect(tab.conversation == before, "the old body back")
        #expect(tab.commentEdits.edits[reviewId] === edit && edit.draft.text == "A better summary")
        #expect(tab.commentEdits.editingInConversation == reviewId, "open again by its link")
        #expect(edit.error?.contains("Resource not accessible") == true)
        #expect(try app.store.conversation(of: tab.id)?.items == tab.conversation?.items, "put back in the store too")
    }

    @Test func whatGitHubDoesntLetTheViewerEditOffersNoEdit() async throws {
        let (app, tab) = try await openConversation()
        let othersComment = "IC_kwDODst66c8AAAABbqiw8A"
        let othersThreadComment = "PRRC_kwDODst66c799auZ"
        #expect(!tab.canEdit(othersComment) && !tab.canEdit(othersThreadComment))
        #expect(tab.canEdit("PRRC_kwDODst66c797-Cp"), "the viewer's own thread comment")
        let page = try conversationPage(tab)
        #expect(!page.contains(CommentLink(editing: othersComment).url.absoluteString))
        #expect(!page.contains(CommentLink(editing: othersThreadComment).url.absoluteString))
        #expect(page.contains(CommentLink(editing: "PRRC_kwDODst66c797-Cp").url.absoluteString))

        await tab.follow(CommentLink(editing: othersComment))
        await tab.startEdit(of: othersThreadComment)
        #expect(tab.commentEdits.edits.isEmpty && tab.commentEdits.editingInConversation == nil)
        #expect(await app.conversations.editsReceived.isEmpty)
    }

    @Test func theViewersSubmittedThreadCommentsAreDeletedAtOnceTheirThreadWithTheLast() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let othersThreadId = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 11, body: "Why three?")
        let ownThreadId = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 12, body: "And this one", by: FakeGitHub.viewer)
        let tab = try await app.open(pullRequest)
        let othersThread = try #require(tab.thread(othersThreadId))
        tab.startReply(to: othersThread)
        try #require(tab.threadActivity.replies[othersThreadId]).text = "Because of the batch size"
        await tab.sendReply(to: othersThread)
        let replied = try #require(tab.thread(othersThreadId))
        let reply = try #require(replied.comments.last)
        #expect(!tab.canDelete(try #require(replied.comments.first).id), "someone else's")
        #expect(tab.canDelete(reply.id))

        await app.conversations.hold(.deleteComment)
        let deleting = Task { await tab.deleteComment(reply, in: replied) }
        await app.conversations.arrival(of: .deleteComment)
        #expect(tab.thread(othersThreadId)?.comments.map(\.id) == [try #require(replied.comments.first).id], "gone at once, the thread kept")
        #expect(tab.placedThreads.first { $0.id == othersThreadId }?.comments.count == 1, "on the diff too")
        #expect(try app.store.conversation(of: tab.id)?.threads == tab.conversation?.threads, "stored as it's shown")
        await app.conversations.release(.deleteComment)
        await deleting.value
        #expect(tab.thread(othersThreadId)?.comments.count == 1)
        #expect(tab.threadActivity.deleting.isEmpty && tab.threadActivity.errors[othersThreadId] == nil)

        let ownThread = try #require(tab.thread(ownThreadId))
        await tab.deleteComment(try #require(ownThread.comments.first), in: ownThread)
        #expect(tab.thread(ownThreadId) == nil, "its only comment gone, the thread goes with it")
        #expect(!tab.placedThreads.contains { $0.id == ownThreadId })
        #expect(await app.conversations.reviewMutationsReceived == [.deleteComment(id: reply.id), .deleteComment(id: try #require(ownThread.comments.first).id)])
    }

    @Test func aRefusedDeletionOfAThreadCommentBringsItBackAndSaysWhy() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let threadId = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 12, body: "And this one", by: FakeGitHub.viewer)
        let tab = try await app.open(pullRequest)
        let thread = try #require(tab.thread(threadId))
        await app.conversations.refuseThreadChanges()

        await tab.deleteComment(try #require(thread.comments.first), in: thread)

        #expect(tab.thread(threadId) == thread, "back as it was")
        #expect(tab.threadActivity.errors[threadId]?.contains("Couldn't delete your comment") == true)
        #expect(try app.store.conversation(of: tab.id)?.threads == tab.conversation?.threads)
    }

    @Test func aCommentOnThePullRequestIsDeletedByItsLinkAfterAsking() async throws {
        let (app, tab, commentId) = try await openConversationWithOwnComment()
        let link = CommentLink(deleting: commentId)
        #expect(try conversationPage(tab).contains(link.url.absoluteString))

        await tab.follow(link)
        #expect(tab.commentEdits.confirmingDeletion == commentId, "asks first")
        tab.commentEdits.keepComment()
        #expect(tab.commentEdits.confirmingDeletion == nil && tab.conversation?.items.contains { $0.id == commentId } == true)
        #expect(await app.conversations.conversationCommentDeletions.isEmpty)

        await tab.follow(link)
        await app.conversations.hold(.deleteConversationComment)
        let deleting = Task { await tab.deleteFromConversation(commentId) }
        await app.conversations.arrival(of: .deleteConversationComment)
        #expect(tab.commentEdits.confirmingDeletion == nil)
        #expect(tab.conversation?.items.contains { $0.id == commentId } == false, "gone at once")
        #expect(try app.store.conversation(of: tab.id)?.items == tab.conversation?.items, "stored as it's shown")

        await app.conversations.release(.deleteConversationComment)
        await deleting.value
        #expect(await app.conversations.conversationCommentDeletions == [commentId])
        #expect(tab.conversation?.items.contains { $0.id == commentId } == false, "and still gone once the conversation is fetched again")
        #expect(tab.commentEdits.deletionError == nil)
    }

    @Test func aRefusedDeletionOfACommentOnThePullRequestBringsItBackAndSaysWhy() async throws {
        let (app, tab, commentId) = try await openConversationWithOwnComment()
        let before = tab.conversation
        await app.conversations.refuseCommentEdits()

        await tab.follow(CommentLink(deleting: commentId))
        await tab.deleteFromConversation(commentId)

        #expect(tab.conversation == before, "back where it was")
        #expect(tab.commentEdits.deletionError?.contains("Resource not accessible") == true)
        #expect(try app.store.conversation(of: tab.id)?.items == tab.conversation?.items)
        tab.commentEdits.dismissDeletionError()
        #expect(tab.commentEdits.deletionError == nil)
    }

    @Test func whatGitHubDoesntLetTheViewerDeleteOffersNoDeletion() async throws {
        let (app, tab) = try await openConversation()
        let othersComment = "IC_kwDODst66c8AAAABbqiw8A"
        let othersThreadComment = "PRRC_kwDODst66c799auZ"
        let ownReview = "PRR_kwDODst66c8AAAABSQ7MWA"
        #expect(!tab.canDelete(othersComment) && !tab.canDelete(othersThreadComment) && !tab.canDelete(ownReview))
        #expect(tab.canDelete("PRRC_kwDODst66c797-Cp"), "the viewer's own thread comment")
        let page = try conversationPage(tab)
        for id in [othersComment, othersThreadComment, ownReview] {
            #expect(!page.contains(CommentLink(deleting: id).url.absoluteString))
        }

        await tab.follow(CommentLink(deleting: othersComment))
        #expect(tab.commentEdits.confirmingDeletion == nil)
        await tab.deleteFromConversation(othersComment)
        #expect(await app.conversations.conversationCommentDeletions.isEmpty)
        #expect(tab.conversation?.items.contains { $0.id == othersComment } == true)
    }

    /// The first PR to review, with a comment of the viewer's added to the probe's conversation,
    /// open in its tab.
    private func openConversationWithOwnComment() async throws -> (ThreadsApp, PullRequestTab, String) {
        let app = try await ThreadsApp()
        let pullRequest = app.tabs.lists.pullRequests(in: .toReview)[0]
        try await app.conversations.add(pullRequest.id, number: pullRequest.number)
        let commentId = await app.conversations.comment("<p dir=\"auto\">Sorry, wrong PR</p>", on: pullRequest.id, by: FakeGitHub.viewer)
        return (app, try await app.open(pullRequest), commentId)
    }

    /// The first PR to review, with the probe's conversation, open in its tab.
    private func openConversation() async throws -> (ThreadsApp, PullRequestTab) {
        let app = try await ThreadsApp()
        let pullRequest = app.tabs.lists.pullRequests(in: .toReview)[0]
        try await app.conversations.add(pullRequest.id, number: pullRequest.number)
        return (app, try await app.open(pullRequest))
    }

    private func conversationPage(_ tab: PullRequestTab) throws -> String {
        ConversationHTML.page(try #require(tab.conversation), template: "{{content}}", stylesheet: "")
    }
}
