import Foundation
import LoupeCore
import LoupeGitHub
import LoupeModel
import Observation

/// The viewer's edits of comments, thread comments and review summaries, each kept from when
/// it's opened until it's saved or dropped, while the tab lives, so putting one away loses
/// nothing; and their deletions asked for on the conversation page.
@Observable
@MainActor
public final class CommentEdits {
    /// Each edit open, by the id of what it edits.
    public internal(set) var edits: [String: CommentEdit] = [:]
    /// What's being edited over the conversation, by its place in the page, by id; its edit is
    /// in `edits`, where the diff shows it too.
    public internal(set) var editingInConversation: String?

    init() {}

    /// Puts away the edit open over the conversation, keeping it, where the page's "Edit" opens
    /// it again and the diff shows a thread comment's.
    public func closeConversationEdit() {
        editingInConversation = nil
    }

    /// The comment whose "Delete" in the conversation page is being confirmed, by id.
    public internal(set) var confirmingDeletion: String?
    /// Why the last deletion asked for on the conversation page didn't reach GitHub, until
    /// it's dismissed or another is asked for.
    public internal(set) var deletionError: String?

    /// Keeps the comment, as the confirmation was declined.
    public func keepComment() {
        confirmingDeletion = nil
    }

    public func dismissDeletionError() {
        deletionError = nil
    }
}

/// An edit of one comment's or review's body. It starts from the markdown fetched afresh from
/// GitHub, not a stored copy, as comments are also edited on github.com and the store keeps
/// only GitHub's rendering.
@Observable
@MainActor
public final class CommentEdit {
    public enum Phase: Sendable, Equatable {
        /// Asking GitHub for the markdown as it is now.
        case fetching
        /// GitHub couldn't be asked, and why; there's nothing safe to edit until it can.
        case fetchFailed(String)
        case editing
    }

    /// The id of what's edited.
    public let commentId: String
    let kind: EditedComment
    public internal(set) var phase = Phase.fetching
    /// The text being edited, starting as GitHub had it.
    public let draft = CommentDraft()
    /// Why the last save didn't reach GitHub, until it's saved again or dropped.
    public internal(set) var error: String?

    init(commentId: String, kind: EditedComment) {
        self.commentId = commentId
        self.kind = kind
    }
}

extension PullRequestTab {
    /// Whether the viewer may edit the comment, thread comment or review with `id`: GitHub says
    /// they may, it has the comment, and no edit of it is being saved. A pending review's summary
    /// is written in "Finish your review" instead, and a review with no summary shows nothing to edit.
    public func canEdit(_ id: String) -> Bool {
        editedComment(id) != nil
    }

    /// Acts on the conversation page's "Edit" of a comment or review, opening its edit over
    /// the conversation by it. Returns once its markdown has arrived or failed.
    public func editInConversation(_ id: String) async {
        guard canEdit(id) else { return }
        commentEdits.editingInConversation = id
        await startEdit(of: id)
    }

    /// Opens an edit of the comment or review with `id`, from its markdown fetched afresh from
    /// GitHub, keeping one already open. Returns once that has arrived or failed.
    public func startEdit(of id: String) async {
        guard commentEdits.edits[id] == nil, let kind = editedComment(id) else { return }
        let edit = CommentEdit(commentId: id, kind: kind)
        commentEdits.edits[id] = edit
        await fetchBody(of: edit)
    }

    /// Asks GitHub again for the markdown of an edit whose fetch failed.
    public func retryFetch(of edit: CommentEdit) async {
        await fetchBody(of: edit)
    }

    /// Drops the edit, leaving the comment as GitHub has it; asking first is the view's job.
    public func cancelEdit(of id: String) {
        commentEdits.edits[id] = nil
        if commentEdits.editingInConversation == id { commentEdits.closeConversationEdit() }
    }

    /// Saves the edit, unless it's empty or unchanged. The comment shows the new text at once,
    /// marked as saving until GitHub answers with its rendering; then the threads, or the
    /// conversation, are fetched again in case of anything else new. A refusal puts the old
    /// body back and opens the edit again as it was, with the reason, over the conversation
    /// too if that's where it was written.
    public func saveEdit(of id: String) async {
        guard let edit = commentEdits.edits[id], edit.phase == .editing, edit.draft.canSend else { return }
        let text = edit.draft.text
        let wasInConversation = commentEdits.editingInConversation == id
        edit.error = nil
        commentEdits.edits[id] = nil
        if wasInConversation { commentEdits.closeConversationEdit() }
        let change = make(.edited(id: id, bodyHTML: plainParagraphs(text), isSaving: true))
        await storeOwnChanges()
        let bodyHTML: String
        do {
            bodyHTML = try await client.updateComment(edit.kind, id: id, body: text)
        } catch {
            undo(change)
            edit.error = "Couldn't save your edit: \(error.localizedDescription)"
            commentEdits.edits[id] = edit
            if wasInConversation, commentEdits.editingInConversation == nil { commentEdits.editingInConversation = id }
            await storeOwnChanges()
            return
        }
        confirm(change, edit: bodyHTML)
        await storeOwnChanges()
        if edit.kind == .reviewComment {
            await refreshThreads { $0.comments.contains { $0.id == id } }
        } else {
            await refreshConversation()
        }
    }
}

extension PullRequestTab {
    /// Whether the viewer may delete the thread comment or the comment on the PR with `id`:
    /// GitHub says they may, or it's in their pending review, and it isn't on its way to GitHub.
    /// Reviews aren't deleted, as GitHub only lets a pending one be, by discarding it.
    public func canDelete(_ id: String) -> Bool {
        guard let conversation else { return false }
        if let comment = conversation.threads.comment(id) {
            return (comment.viewerCanDelete || comment.isPending) && !comment.isSending && !comment.isSaving && !threadActivity.deleting.contains(id)
        }
        guard let item = conversation.items.first(where: { $0.id == id }), case .comment = item.event else { return false }
        return item.viewerCanDelete && !item.isSending && !item.isSaving
    }

    /// Acts on the conversation page's "Delete" of a comment, asking first.
    func askToDelete(_ id: String) {
        guard canDelete(id) else { return }
        commentEdits.deletionError = nil
        commentEdits.confirmingDeletion = id
    }

    /// Deletes the comment with `id` once its deletion is confirmed on the conversation page.
    /// Why GitHub refused shows over the page, as well as on the thread's card for a thread
    /// comment.
    public func deleteFromConversation(_ id: String) async {
        commentEdits.confirmingDeletion = nil
        if let thread = conversation?.threads.first(where: { $0.comments.contains { $0.id == id } }), let comment = thread.comments.first(where: { $0.id == id }) {
            await deleteComment(comment, in: thread)
            commentEdits.deletionError = threadActivity.errors[thread.id]
        } else {
            await deleteConversationComment(id)
        }
    }

    /// Deletes one of the viewer's thread comments, pending or submitted, and its thread with it
    /// if it was the only comment. It goes at once, and comes back if GitHub refuses, saying why
    /// on the thread; then the thread is fetched again. An edit of it open is dropped.
    public func deleteComment(_ comment: ThreadComment, in thread: ReviewThread) async {
        guard canDelete(comment.id) else { return }
        cancelEdit(of: comment.id)
        // A pending one may leave its review empty, which has its own tidying.
        if comment.isPending { return await deletePendingComment(comment, in: thread) }
        threadActivity.deleting.insert(comment.id)
        threadActivity.errors[thread.id] = nil
        defer { threadActivity.deleting.remove(comment.id) }
        let change = make(.deleted(commentId: comment.id))
        await storeOwnChanges()
        do {
            try await client.deleteReviewComment(comment.id)
        } catch {
            undo(change)
            threadActivity.errors[thread.id] = "Couldn't delete your comment: \(error.localizedDescription)"
            await storeOwnChanges()
            return
        }
        confirm(change)
        await refreshThreads { $0.id == thread.id }
    }

    /// Deletes one of the viewer's comments on the PR itself. It goes at once, and comes back if
    /// GitHub refuses, with why over the page; then the conversation is fetched again.
    func deleteConversationComment(_ id: String) async {
        guard canDelete(id) else { return }
        cancelEdit(of: id)
        let change = make(.deleted(commentId: id))
        await storeOwnChanges()
        do {
            try await client.deleteIssueComment(id)
        } catch {
            undo(change)
            commentEdits.deletionError = "Couldn't delete your comment: \(error.localizedDescription)"
            await storeOwnChanges()
            return
        }
        confirm(change)
        await refreshConversation()
    }
}

private extension PullRequestTab {
    /// What kind of thing `id` is, if the viewer may edit it now.
    func editedComment(_ id: String) -> EditedComment? {
        guard let conversation else { return nil }
        if let comment = conversation.threads.comment(id) {
            return comment.viewerCanUpdate && !comment.isSending && !comment.isSaving ? .reviewComment : nil
        }
        guard let item = conversation.items.first(where: { $0.id == id }), item.viewerCanUpdate, !item.isSending, !item.isSaving else { return nil }
        switch item.event {
        case .comment: return .issueComment
        case let .review(state, bodyHTML, _): return state != .pending && !bodyHTML.isEmpty ? .review : nil
        default: return nil
        }
    }

    /// Fills the edit with the markdown as GitHub has it now. GitHub keeps line endings as typed
    /// in a browser; the editor's are newlines, so an untouched comment isn't counted as changed.
    func fetchBody(of edit: CommentEdit) async {
        edit.phase = .fetching
        do {
            let body = try await client.commentBody(id: edit.commentId).replacingOccurrences(of: "\r\n", with: "\n")
            edit.draft.original = body
            edit.draft.text = body
            edit.phase = .editing
        } catch {
            edit.phase = .fetchFailed(error.localizedDescription)
        }
    }
}
