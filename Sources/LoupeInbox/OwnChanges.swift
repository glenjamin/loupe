import Foundation
import LoupeCore
import LoupeGitHub
import LoupeModel

/// A change of the viewer's to the conversation, shown before GitHub has answered for it. It's
/// made again over each fetch that may have started before GitHub had it, so a fetch landing
/// meanwhile doesn't take it away, and it's undone if GitHub refuses it.
struct OwnChange {
    let id: Int
    var kind: Kind
    /// What it replaced, to put back if GitHub refuses it.
    let undo: Undo
    /// How many fetches had started by the time GitHub answered for it; nil until it has. A
    /// fetch started since has it; one started before may not, so the change is kept until
    /// none of those is underway.
    var answeredBefore: Int?

    enum Kind {
        /// A comment added to `thread`, or starting it, as a thread GitHub doesn't have yet. One
        /// starting a thread also shows in the timeline, in the review GitHub puts it in:
        /// `reviewId`'s, if known.
        case comment(ThreadComment, thread: ReviewThread, startsThread: Bool, reviewId: String?)
        case resolved(threadId: String, Bool, by: String?)
        /// One of the viewer's pending comments deleted.
        case deleted(commentId: String)
        /// The viewer's pending review abandoned, with its comments.
        case discarded(reviewId: String)
        /// The viewer's review submitted: its comments no longer pending, and `review` in the
        /// timeline in place of the pending one.
        case submitted(TimelineItem)
        /// A comment on the PR itself, at the end of the timeline.
        case conversationComment(TimelineItem)
    }

    /// What a change replaced in the conversation, and on the diff where its threads were held.
    struct Undo {
        let conversation: ConversationUndo?
        let placedThreads: ThreadsUndo?
    }

    /// The id given to a comment, thread or review until GitHub gives its own.
    static func provisionalId() -> String {
        provisionalPrefix + UUID().uuidString
    }

    static func isProvisional(_ id: String) -> Bool {
        id.hasPrefix(provisionalPrefix)
    }

    private static let provisionalPrefix = "loupe-sending-"
}

/// The threads a change altered as they were, by position, and what it added.
struct ThreadsUndo {
    var changed: [(index: Int, thread: ReviewThread)] = []
    var addedThreads: Set<String> = []
    var addedComments: Set<String> = []

    init(from before: [ReviewThread], to after: [ReviewThread]) {
        let afterById = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, thread) in before.enumerated() where afterById[thread.id] != thread {
            changed.append((index, thread))
        }
        addedThreads = Set(after.map(\.id)).subtracting(before.map(\.id))
        addedComments = Set(after.flatMap(\.comments).map(\.id)).subtracting(before.flatMap(\.comments).map(\.id))
    }
}

/// The timeline items and pending review a change altered as they were, besides its threads.
struct ConversationUndo {
    let threads: ThreadsUndo
    var changedItems: [(index: Int, item: TimelineItem)] = []
    var addedItems: Set<String> = []
    /// The pending review as it was, if the change altered it.
    var pendingReview: PendingReview??

    init(from before: Conversation, to after: Conversation) {
        threads = ThreadsUndo(from: before.threads, to: after.threads)
        let afterById = Dictionary(after.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, item) in before.items.enumerated() where afterById[item.id] != item {
            changedItems.append((index, item))
        }
        addedItems = Set(after.items.map(\.id)).subtracting(before.items.map(\.id))
        pendingReview = before.pendingReview == after.pendingReview ? nil : .some(before.pendingReview)
    }
}

extension PullRequestTab {
    /// Makes the viewer's change at once, in the conversation and on the diff shown, the diff's
    /// threads included while they're held for new commits, and returns it to confirm or undo
    /// once GitHub answers. Storing it is the caller's, after this, so nothing waits first.
    func make(_ kind: OwnChange.Kind) -> Int {
        let before = conversation
        conversation?.make(kind)
        var placedUndo: ThreadsUndo?
        if holdsPlacedThreads {
            let placed = threadsOfShownDiff
            threadsOfShownDiff.make(kind)
            placedUndo = ThreadsUndo(from: placed, to: threadsOfShownDiff)
        } else {
            followPlacedThreads()
        }
        let conversationUndo = before.flatMap { before in conversation.map { ConversationUndo(from: before, to: $0) } }
        let id = nextOwnChange
        nextOwnChange += 1
        ownChanges.append(OwnChange(id: id, kind: kind, undo: OwnChange.Undo(conversation: conversationUndo, placedThreads: placedUndo)))
        return id
    }

    /// GitHub has the comment: it takes the provisional one's place, in its thread and in the
    /// timeline, with GitHub's id, rendering and time, and is what's made again over a fetch
    /// that started too soon to have it. `threadId` and `reviewId` name the thread and review
    /// it's in, where GitHub said.
    func confirm(_ change: Int, comment provisionalId: String, as comment: ThreadComment, threadId: String?, reviewId: String?) {
        guard let index = ownChanges.firstIndex(where: { $0.id == change }), case let .comment(_, thread, startsThread, _) = ownChanges[index].kind else { return }
        var confirmedThread = thread
        if let threadId, OwnChange.isProvisional(thread.id) { confirmedThread.id = threadId }
        ownChanges[index].kind = .comment(comment, thread: confirmedThread, startsThread: startsThread, reviewId: reviewId)
        ownChanges[index].answeredBefore = fetchesStarted
        conversation?.confirm(provisionalId, as: comment, threadId: threadId, reviewId: reviewId)
        if holdsPlacedThreads {
            threadsOfShownDiff.confirm(provisionalId, as: comment, threadId: threadId)
        } else {
            followPlacedThreads()
        }
    }

    /// GitHub has the review submitted: it takes the provisional one's place in the timeline.
    func confirm(_ change: Int, review provisionalId: String, as posted: PostedReview) {
        guard let index = ownChanges.firstIndex(where: { $0.id == change }), case let .submitted(item) = ownChanges[index].kind else { return }
        let review = TimelineItem(
            id: posted.id, date: posted.date, actor: posted.author ?? item.actor,
            event: .review(state: posted.state, bodyHTML: posted.bodyHTML, comments: item.reviewComments)
        )
        ownChanges[index].kind = .submitted(review)
        ownChanges[index].answeredBefore = fetchesStarted
        guard let at = conversation?.items.firstIndex(where: { $0.id == provisionalId }) else { return }
        conversation?.items[at] = review
    }

    /// GitHub has the comment on the PR: its copy takes the provisional one's place in the
    /// timeline, and is what's made again over a fetch that started too soon to have it.
    func confirm(_ change: Int, conversationComment provisionalId: String, as posted: TimelineItem) {
        guard let index = ownChanges.firstIndex(where: { $0.id == change }), case .conversationComment = ownChanges[index].kind else { return }
        ownChanges[index].kind = .conversationComment(posted)
        ownChanges[index].answeredBefore = fetchesStarted
        guard let at = conversation?.items.firstIndex(where: { $0.id == provisionalId }) else { return }
        conversation?.items[at] = posted
    }

    /// GitHub has carried out the change as made, so it's made again only over a fetch that
    /// started too soon to have it.
    func confirm(_ change: Int) {
        guard let index = ownChanges.firstIndex(where: { $0.id == change }) else { return }
        ownChanges[index].answeredBefore = fetchesStarted
    }

    /// GitHub refused the change: what it replaced is put back, and it's forgotten.
    func undo(_ change: Int) {
        guard let index = ownChanges.firstIndex(where: { $0.id == change }) else { return }
        let undo = ownChanges.remove(at: index).undo
        if let conversationUndo = undo.conversation { conversation?.undo(conversationUndo) }
        if let placed = undo.placedThreads, holdsPlacedThreads {
            threadsOfShownDiff.undo(placed)
        } else {
            followPlacedThreads()
        }
    }

    /// Counts a fetch of the conversation or its threads as it starts, and returns its place,
    /// to tell which of the viewer's changes it can have once it lands. Each is ended with
    /// `endFetch`, landed or not.
    func startFetch() -> Int {
        defer { fetchesStarted += 1 }
        fetchesUnderway.insert(fetchesStarted)
        return fetchesStarted
    }

    /// Forgets the viewer's changes no fetch underway can lack, as each started after GitHub
    /// answered for them.
    func endFetch(_ started: Int) {
        fetchesUnderway.remove(started)
        ownChanges.removeAll { change in
            guard let answered = change.answeredBefore else { return false }
            return fetchesUnderway.allSatisfy { $0 >= answered }
        }
    }

    /// Makes the viewer's changes again over what a fetch brought: those GitHub hadn't answered
    /// for when it started, which it may not have.
    func remakeOwnChanges(over fetched: inout Conversation, fetchedFrom started: Int) {
        for change in ownChanges where change.answeredBefore.map({ $0 > started }) ?? true {
            fetched.make(change.kind)
        }
    }

    /// Stores the conversation with the viewer's changes in it, so they're there on the next
    /// launch until it's fetched again.
    func storeOwnChanges() async {
        guard let conversation else { return }
        do {
            try await store.saveViewersChanges(of: id, in: conversation)
        } catch {
            FileHandle.standardError.write(Data("Couldn't store your changes to \(title): \(error)\n".utf8))
        }
    }

    /// A comment of the viewer's on its way: `text` as plain paragraphs until GitHub renders it.
    func sendingComment(_ text: String, isPending: Bool) -> ThreadComment {
        ThreadComment(
            id: OwnChange.provisionalId(), author: viewerParticipant, createdAt: .now, bodyHTML: plainParagraphs(text),
            isMinimized: false, isPending: isPending, isSending: true
        )
    }

    /// A review of the viewer's on its way, with `summary` as plain paragraphs until GitHub
    /// renders it, in place of the pending review `reviewId` if there is one.
    func sendingReview(_ state: ReviewState, summary: String, replacing reviewId: String?) -> TimelineItem {
        let comments: [ReviewComment] = conversation?.items.first { $0.id == reviewId }.flatMap { item in
            if case let .review(_, _, comments) = item.event { comments } else { nil }
        } ?? []
        let bodyHTML = summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : plainParagraphs(summary)
        return TimelineItem(
            id: reviewId ?? OwnChange.provisionalId(), date: .now, actor: viewerParticipant,
            event: .review(state: state, bodyHTML: bodyHTML, comments: comments), isSending: true
        )
    }

    /// A comment of the viewer's on the PR on its way, with `text` as plain paragraphs until
    /// GitHub renders it.
    func sendingConversationComment(_ text: String) -> TimelineItem {
        TimelineItem(
            id: OwnChange.provisionalId(), date: .now, actor: viewerParticipant,
            event: .comment(bodyHTML: plainParagraphs(text), isMinimized: false), isSending: true
        )
    }

    /// A thread for a comment the viewer is starting on `anchor`, until GitHub says which
    /// thread it made, with the diff's lines up to it as GitHub keeps them.
    func sendingThread(at anchor: DiffAnchor, in review: ReviewDiff) -> ReviewThread {
        let file = review.changes.files.first { $0.path == anchor.path } ?? lastHiddenFileDiff(of: anchor.path)
        return ReviewThread(
            id: OwnChange.provisionalId(), isResolved: false, isOutdated: false, path: anchor.path, line: anchor.line,
            side: anchor.side == .left ? .left : .right, originalLine: anchor.line,
            diffHunk: file.map { diffHunk(endingOn: anchor, in: expandedFile($0)) } ?? "", comments: []
        )
    }

    /// The viewer as an author, with their avatar if any of their comments shows it.
    private var viewerParticipant: Participant? {
        guard let viewer else { return nil }
        let commenters: [Participant] = conversation?.threads.flatMap(\.comments).compactMap(\.author) ?? []
        let actors: [Participant] = conversation?.items.compactMap(\.actor) ?? []
        let known = (commenters + actors).first { $0.login == viewer && $0.avatarURL != nil }
        return known ?? Participant(login: viewer, avatarURL: nil)
    }
}

extension Conversation {
    /// Makes the change, unless GitHub's copy already shows it.
    mutating func make(_ change: OwnChange.Kind) {
        switch change {
        case let .comment(comment, thread, startsThread, reviewId):
            guard threads.comment(comment.id) == nil else { return }
            threads.make(change)
            if comment.isPending {
                if pendingReview == nil, let reviewId { pendingReview = PendingReview(id: reviewId, body: "", commentCount: 0) }
                pendingReview?.commentCount += 1
            }
            if startsThread { showInTimeline(comment, startingThread: thread, inReview: reviewId) }
        case .resolved:
            threads.make(change)
        case let .deleted(commentId):
            guard let deleted = threads.comment(commentId) else { return }
            threads.make(change)
            if deleted.isPending { pendingReview?.commentCount -= 1 }
            removeFromTimeline(commentId)
        case let .discarded(reviewId):
            threads.make(change)
            pendingReview = nil
            items.removeAll { $0.id == reviewId || $0.isPendingReview }
        case let .submitted(review):
            threads.make(change)
            pendingReview = nil
            guard let index = items.firstIndex(where: { $0.id == review.id }) else { return items.append(review) }
            // GitHub's copy, once submitted, is the one to show.
            guard items[index].isSending || items[index].isPendingReview else { return }
            items[index] = review
        case let .conversationComment(comment):
            guard !items.contains(where: { $0.id == comment.id }) else { return }
            items.append(comment)
        }
    }

    /// Gives the provisional comment GitHub's copy, in its thread and in the timeline, and its
    /// thread and review the ids GitHub gave them.
    mutating func confirm(_ provisionalId: String, as comment: ThreadComment, threadId: String?, reviewId: String?) {
        threads.confirm(provisionalId, as: comment, threadId: threadId)
        for index in items.indices {
            guard case let .review(state, bodyHTML, comments) = items[index].event, let at = comments.firstIndex(where: { $0.id == provisionalId }) else { continue }
            var confirmed = comments
            confirmed[at].id = comment.id
            confirmed[at].bodyHTML = comment.bodyHTML
            items[index].event = .review(state: state, bodyHTML: bodyHTML, comments: confirmed)
            items[index].isSending = false
            if let reviewId, OwnChange.isProvisional(items[index].id) { items[index].id = reviewId }
        }
        if comment.isPending, pendingReview == nil, let reviewId {
            pendingReview = PendingReview(id: reviewId, body: "", commentCount: threads.flatMap(\.comments).count(where: \.isPending))
        }
    }

    /// Puts back what a refused change replaced, and takes away what it added.
    mutating func undo(_ undo: ConversationUndo) {
        threads.undo(undo.threads)
        items.removeAll { undo.addedItems.contains($0.id) }
        for index in items.indices {
            guard case let .review(state, bodyHTML, comments) = items[index].event, comments.contains(where: { undo.threads.addedComments.contains($0.id) }) else { continue }
            items[index].event = .review(state: state, bodyHTML: bodyHTML, comments: comments.filter { !undo.threads.addedComments.contains($0.id) })
        }
        for (index, item) in undo.changedItems {
            if let at = items.firstIndex(where: { $0.id == item.id }) {
                items[at] = item
            } else {
                items.insert(item, at: min(index, items.count))
            }
        }
        if let pending = undo.pendingReview { pendingReview = pending }
    }

    /// Shows a comment starting a thread in the timeline, as GitHub does in the review it's in:
    /// the viewer's pending review for a pending one, or a review of its own.
    private mutating func showInTimeline(_ comment: ThreadComment, startingThread thread: ReviewThread, inReview reviewId: String?) {
        guard !items.contains(where: { $0.reviewComments.contains { $0.id == comment.id } }) else { return }
        let started = ReviewComment(
            id: comment.id, bodyHTML: comment.bodyHTML, path: thread.path, line: thread.line, originalLine: thread.originalLine ?? thread.line,
            diffHunk: thread.diffHunk, isOutdated: false, isMinimized: false, replyTo: nil
        )
        if comment.isPending, let index = items.firstIndex(where: { $0.id == reviewId || $0.isPendingReview }),
           case let .review(state, bodyHTML, comments) = items[index].event {
            items[index].event = .review(state: state, bodyHTML: bodyHTML, comments: comments + [started])
            return
        }
        items.append(TimelineItem(
            id: reviewId ?? OwnChange.provisionalId(), date: comment.createdAt, actor: comment.author,
            event: .review(state: comment.isPending ? .pending : .commented, bodyHTML: "", comments: [started]), isSending: comment.isSending
        ))
    }

    private mutating func removeFromTimeline(_ commentId: String) {
        for index in items.indices {
            guard case let .review(state, bodyHTML, comments) = items[index].event, comments.contains(where: { $0.id == commentId }) else { continue }
            items[index].event = .review(state: state, bodyHTML: bodyHTML, comments: comments.filter { $0.id != commentId })
        }
    }
}

extension [ReviewThread] {
    /// Makes the change to the threads alone.
    mutating func make(_ change: OwnChange.Kind) {
        switch change {
        case let .comment(comment, thread, _, _):
            guard self.comment(comment.id) == nil else { return }
            if let index = firstIndex(where: { $0.id == thread.id }) {
                self[index].comments.append(comment)
            } else {
                var started = thread
                started.comments.append(comment)
                append(started)
            }
        case let .resolved(threadId, resolved, by):
            guard let index = firstIndex(where: { $0.id == threadId }) else { return }
            self[index].isResolved = resolved
            self[index].resolvedBy = resolved ? by : nil
            // Whoever can resolve a thread can unresolve it, and the other way round.
            self[index].viewerCanResolve = !resolved
            self[index].viewerCanUnresolve = resolved
        case let .deleted(commentId):
            removeComments { $0.id == commentId }
        case .discarded:
            removeComments(where: \.isPending)
        case .submitted:
            for index in indices where self[index].comments.contains(where: \.isPending) {
                for at in self[index].comments.indices { self[index].comments[at].isPending = false }
            }
        case .conversationComment:
            break
        }
    }

    /// Gives the provisional comment GitHub's copy, and its provisional thread GitHub's id.
    mutating func confirm(_ provisionalId: String, as comment: ThreadComment, threadId: String?) {
        for index in indices {
            guard let at = self[index].comments.firstIndex(where: { $0.id == provisionalId }) else { continue }
            self[index].comments[at] = comment
            if let threadId, OwnChange.isProvisional(self[index].id) { self[index].id = threadId }
        }
    }

    /// Puts back the threads a refused change altered, and takes away what it added.
    mutating func undo(_ undo: ThreadsUndo) {
        removeAll { undo.addedThreads.contains($0.id) }
        for index in indices {
            self[index].comments.removeAll { undo.addedComments.contains($0.id) }
        }
        for (index, thread) in undo.changed {
            guard let at = firstIndex(where: { $0.id == thread.id }) else {
                insert(thread, at: Swift.min(index, count))
                continue
            }
            var comments = self[at].comments
            for (position, comment) in thread.comments.enumerated() {
                if let existing = comments.firstIndex(where: { $0.id == comment.id }) {
                    comments[existing] = comment
                } else {
                    comments.insert(comment, at: Swift.min(position, comments.count))
                }
            }
            var restored = thread
            restored.comments = comments
            self[at] = restored
        }
    }

    func comment(_ id: String) -> ThreadComment? {
        lazy.flatMap(\.comments).first { $0.id == id }
    }

    /// Takes away the comments, and any thread left with none.
    private mutating func removeComments(where removed: (ThreadComment) -> Bool) {
        self = compactMap { thread in
            guard thread.comments.contains(where: removed) else { return thread }
            var kept = thread
            kept.comments.removeAll(where: removed)
            return kept.comments.isEmpty ? nil : kept
        }
    }
}

private extension TimelineItem {
    var reviewComments: [ReviewComment] {
        if case let .review(_, _, comments) = event { comments } else { [] }
    }

    var isPendingReview: Bool {
        if case .review(.pending, _, _) = event { true } else { false }
    }
}

/// The lines of the file's diff up to `anchor`'s, in its hunk, as GitHub keeps a comment's hunk.
private func diffHunk(endingOn anchor: DiffAnchor, in file: FileDiff) -> String {
    for hunk in file.hunks {
        guard let end = hunk.lines.firstIndex(where: { (anchor.side == .left ? $0.oldLine : $0.newLine) == anchor.line }) else { continue }
        let rows = hunk.lines[...end].map { diffLine in
            let marker = diffLine.isAddition ? "+" : diffLine.isDeletion ? "-" : " "
            return marker + diffLine.text
        }
        return (["@@ -\(hunk.oldStart) +\(hunk.newStart) @@"] + rows).joined(separator: "\n")
    }
    return ""
}

/// `text` as HTML paragraphs, escaped, a blank line between each, until GitHub renders it.
private func plainParagraphs(_ text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "\r\n", with: "\n")
    return escaped.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n\n")
        .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>\n"))</p>" }
        .joined(separator: "\n")
}
