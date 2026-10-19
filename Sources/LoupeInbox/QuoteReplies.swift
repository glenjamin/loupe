import Foundation
import LoupeCore
import LoupeModel

extension PullRequestTab {
    /// Quotes `markdown`, selected in a comment on the conversation page, into the reply to the
    /// thread it's in, over the conversation, or into the comment on the PR when it's in no
    /// thread or one the viewer can't reply to there. Anything already written is kept, the
    /// quote after it.
    public func quoteInConversation(_ markdown: String, fromThread threadId: String?) {
        let quote = QuoteReply.quoted(markdown)
        guard !quote.isEmpty else { return }
        if let thread = threadId.flatMap(reviewThread), thread.viewerCanReply, !thread.isPending {
            replyInConversation(to: thread)
            if let draft = threadActivity.replies[thread.id] { draft.addQuote(quote) }
            return
        }
        startConversationComment()
        conversationComment.draft?.addQuote(quote)
    }

    /// Quotes `markdown`, selected in one of the thread's comments, into its reply, opening one
    /// if need be, and returns whether it could; a thread in the viewer's pending review, or
    /// one they can't reply to, takes none.
    @discardableResult
    public func quoteInReply(_ markdown: String, to thread: ReviewThread) -> Bool {
        let quote = QuoteReply.quoted(markdown)
        guard !quote.isEmpty, thread.viewerCanReply, !thread.isPending else { return false }
        startReply(to: thread)
        guard let draft = threadActivity.replies[thread.id] else { return false }
        draft.addQuote(quote)
        return true
    }
}

extension CommentDraft {
    /// Adds the quote after what's written and asks for the focus, the cursor after it.
    fileprivate func addQuote(_ quote: String) {
        text = QuoteReply.appending(quote, to: text)
        focusRequests += 1
    }
}
