import Foundation
import LoupeCore
import LoupeModel
import Observation

/// The comment being written on the PR itself, as in github.com's box at the foot of its
/// conversation, rather than on a line or in a review. Kept while the tab lives, so putting it
/// away doesn't lose the draft.
@Observable
@MainActor
public final class ConversationComment {
    /// What's typed, from when it's started until it's sent or dropped.
    public internal(set) var draft: CommentDraft?
    /// Whether it's being written over the conversation, by the page's "Add a comment…".
    public internal(set) var isOpen = false
    /// Why the last one didn't reach GitHub, until it's sent again or dropped.
    public internal(set) var error: String?

    init() {}

    /// Puts it away, keeping the draft, where "Add a comment…" opens it again.
    public func close() {
        isOpen = false
    }
}

extension PullRequestTab {
    /// Acts on the conversation page's "Add a comment…".
    public func follow(_ link: CommentLink) {
        startConversationComment()
    }

    /// Opens a comment on the PR over the conversation, keeping one already being written.
    public func startConversationComment() {
        let comment = conversationComment
        if comment.draft == nil { comment.draft = CommentDraft() }
        comment.isOpen = true
    }

    /// Drops the comment being written on the PR; asking first is the view's job.
    public func cancelConversationComment() {
        conversationComment.draft = nil
        conversationComment.error = nil
        conversationComment.isOpen = false
    }

    /// Posts the comment on the PR at once, as typed, for GitHub to render. It shows at the end
    /// of the conversation straight away, marked as sending until GitHub answers with its copy;
    /// then the conversation is fetched again in case of anything else new. A refusal takes it
    /// away and opens the draft again with the reason.
    public func sendConversationComment() async {
        let comment = conversationComment
        guard let draft = comment.draft, draft.canSend else { return }
        comment.error = nil
        let text = draft.text
        let sending = sendingConversationComment(text)
        comment.draft = nil
        comment.isOpen = false
        let change = make(.conversationComment(sending))
        await storeOwnChanges()
        let posted: TimelineItem
        do {
            posted = try await client.addComment(text, toPullRequest: id)
        } catch {
            undo(change)
            reopen(draft)
            comment.error = "Couldn't comment: \(error.localizedDescription)"
            await storeOwnChanges()
            return
        }
        confirm(change, conversationComment: sending.id, as: posted)
        await storeOwnChanges()
        await refreshConversation()
    }

    /// Opens a refused comment again as it was. One started since keeps what's typed in it,
    /// after the refused text.
    private func reopen(_ draft: CommentDraft) {
        let comment = conversationComment
        if let current = comment.draft, current.hasText {
            current.text = draft.text + "\n\n" + current.text
        } else {
            comment.draft = draft
        }
        comment.isOpen = true
    }
}
