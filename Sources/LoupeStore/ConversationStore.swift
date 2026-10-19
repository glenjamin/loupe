import Foundation
import GRDB
import LoupeModel

extension PullRequestStore {
    /// The PR's conversation as last stored, or nil if it never has been.
    public func conversation(of pullRequestId: String) throws -> Conversation? {
        try database.read { db in
            guard let row = try ConversationRow.fetchOne(db, key: pullRequestId) else { return nil }
            let byPR = Column("pullRequestId") == pullRequestId
            let comments = Dictionary(grouping: try ReviewCommentRow.filter(byPR).order(Column("position")).fetchAll(db), by: \.reviewId)
            let threadComments = Dictionary(grouping: try ThreadCommentRow.filter(byPR).order(Column("position")).fetchAll(db), by: \.threadId)
            let reviewers = try ReviewerRow.filter(byPR).order(Column("position")).fetchAll(db)
            let reactions = Dictionary(grouping: try ReactionRow.filter(byPR).fetchAll(db), by: \.subjectId).mapValues { rows in
                [ReactionGroup](shown: rows.compactMap(\.group))
            }
            return Conversation(
                id: pullRequestId,
                author: participant(row.authorLogin, row.authorAvatarUrl),
                createdAt: row.createdAt,
                bodyHTML: row.bodyHTML,
                body: row.body,
                reactions: reactions[pullRequestId] ?? [],
                items: try TimelineItemRow.filter(byPR).order(Column("position")).fetchAll(db).compactMap { item in
                    var timelineItem = item.timelineItem(comments: comments[item.id] ?? [])
                    timelineItem?.reactions = reactions[item.id] ?? []
                    return timelineItem
                },
                threads: try ReviewThreadRow.filter(byPR).order(Column("position")).fetchAll(db).map { thread in
                    thread.thread(comments: (threadComments[thread.id] ?? []).map { row in
                        var comment = row.comment
                        comment.reactions = reactions[comment.id] ?? []
                        return comment
                    })
                },
                checks: try CheckContextRow.filter(byPR).order(Column("position")).fetchAll(db).map { check in
                    CheckContext(name: check.name, status: CheckStatus(rawValue: check.status) ?? .neutral, description: check.description, url: check.url)
                },
                reviewRequests: reviewers.filter { $0.role == ReviewerRow.request }.compactMap(\.reviewer),
                latestReviews: reviewers.filter { $0.role == ReviewerRow.review }.compactMap(\.latestReview),
                pendingReview: row.pendingReview,
                viewerReview: row.viewerReview
            )
        }
    }

    /// Makes the PR's stored conversation exactly `conversation`, as GitHub returned it.
    public func replaceConversation(of pullRequestId: String, with conversation: Conversation, fetchedAt: Date) async throws {
        try await database.write { db in
            for table in ["timelineItem", "reviewComment", "reviewThread", "threadComment", "checkContext", "conversationReviewer", "reaction"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE pullRequestId = ?", arguments: [pullRequestId])
            }
            try ConversationRow(
                pullRequestId: pullRequestId,
                authorLogin: conversation.author?.login,
                authorAvatarUrl: conversation.author?.avatarURL,
                createdAt: conversation.createdAt,
                bodyHTML: conversation.bodyHTML,
                body: conversation.body,
                fetchedAt: fetchedAt,
                pendingReviewId: conversation.pendingReview?.id,
                pendingReviewBody: conversation.pendingReview?.body,
                pendingReviewCommentCount: conversation.pendingReview?.commentCount,
                viewerReviewCommitOid: conversation.viewerReview?.commitOid,
                viewerReviewedAt: conversation.viewerReview?.submittedAt,
                viewerReviewState: conversation.viewerReview?.state.rawValue
            ).upsert(db)
            try insertReactions(conversation.reactions, of: pullRequestId, in: pullRequestId, db)
            try insertTimeline(conversation.items, of: pullRequestId, in: db)
            try insertThreads(conversation.threads, of: pullRequestId, in: db)
            for (position, check) in conversation.checks.enumerated() {
                try CheckContextRow(pullRequestId: pullRequestId, position: position, name: check.name, status: check.status.rawValue, description: check.description, url: check.url).insert(db)
            }
            for (position, reviewer) in conversation.reviewRequests.enumerated() {
                try ReviewerRow(reviewer, role: ReviewerRow.request, pullRequestId: pullRequestId, position: position).insert(db)
            }
            for (position, review) in conversation.latestReviews.enumerated() {
                var row = ReviewerRow(review.reviewer, role: ReviewerRow.review, pullRequestId: pullRequestId, position: position)
                row.reviewState = review.state.rawValue
                row.submittedAt = review.submittedAt
                try row.insert(db)
            }
        }
    }
}

extension PullRequestStore {
    /// Makes the stored conversation's review threads exactly `threads`, and the viewer's
    /// pending review `pendingReview`, as when only they have been fetched again. Does nothing if
    /// no conversation is stored for the PR.
    public func replaceThreads(of pullRequestId: String, with threads: [ReviewThread], pendingReview: PendingReview?) async throws {
        try await database.write { db in
            guard var row = try ConversationRow.fetchOne(db, key: pullRequestId) else { return }
            try db.execute(
                sql: "DELETE FROM reaction WHERE pullRequestId = ? AND subjectId IN (SELECT id FROM threadComment WHERE pullRequestId = ?)",
                arguments: [pullRequestId, pullRequestId]
            )
            for table in ["reviewThread", "threadComment"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE pullRequestId = ?", arguments: [pullRequestId])
            }
            try insertThreads(threads, of: pullRequestId, in: db)
            row.pendingReviewId = pendingReview?.id
            row.pendingReviewBody = pendingReview?.body
            row.pendingReviewCommentCount = pendingReview?.commentCount
            try row.update(db)
        }
    }

    /// Stores the viewer's own changes to the conversation, made before GitHub has answered for
    /// them: `conversation`'s timeline, review threads and pending review replace those stored,
    /// and the rest is left as last fetched. Does nothing if no conversation is stored for the PR.
    public func saveViewersChanges(of pullRequestId: String, in conversation: Conversation) async throws {
        try await database.write { db in
            guard var row = try ConversationRow.fetchOne(db, key: pullRequestId) else { return }
            // Every reaction but the description's is on a timeline item or thread comment.
            try db.execute(sql: "DELETE FROM reaction WHERE pullRequestId = ? AND subjectId != ?", arguments: [pullRequestId, pullRequestId])
            for table in ["timelineItem", "reviewComment", "reviewThread", "threadComment"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE pullRequestId = ?", arguments: [pullRequestId])
            }
            try insertTimeline(conversation.items, of: pullRequestId, in: db)
            try insertThreads(conversation.threads, of: pullRequestId, in: db)
            row.pendingReviewId = conversation.pendingReview?.id
            row.pendingReviewBody = conversation.pendingReview?.body
            row.pendingReviewCommentCount = conversation.pendingReview?.commentCount
            row.viewerReviewCommitOid = conversation.viewerReview?.commitOid
            row.viewerReviewedAt = conversation.viewerReview?.submittedAt
            row.viewerReviewState = conversation.viewerReview?.state.rawValue
            try row.update(db)
        }
    }
}

private func insertTimeline(_ items: [TimelineItem], of pullRequestId: String, in db: Database) throws {
    for (position, item) in items.enumerated() {
        try TimelineItemRow(item, pullRequestId: pullRequestId, position: position).insert(db)
        try insertReactions(item.reactions, of: item.id, in: pullRequestId, db)
        guard case let .review(_, _, comments) = item.event else { continue }
        for (position, comment) in comments.enumerated() {
            try ReviewCommentRow(comment, reviewId: item.id, pullRequestId: pullRequestId, position: position).insert(db)
        }
    }
}

extension PullRequestStore {
    /// Makes the reactions stored for the PR's description, comment, review or thread comment
    /// with `subjectId` exactly `groups`, as when the viewer reacts.
    public func replaceReactions(of subjectId: String, in pullRequestId: String, with groups: [ReactionGroup]) async throws {
        try await database.write { db in
            try ReactionRow.filter(Column("pullRequestId") == pullRequestId && Column("subjectId") == subjectId).deleteAll(db)
            try insertReactions(groups, of: subjectId, in: pullRequestId, db)
        }
    }
}

private func insertThreads(_ threads: [ReviewThread], of pullRequestId: String, in db: Database) throws {
    for (position, thread) in threads.enumerated() {
        try ReviewThreadRow(thread, pullRequestId: pullRequestId, position: position).insert(db)
        for (position, comment) in thread.comments.enumerated() {
            try ThreadCommentRow(comment, threadId: thread.id, pullRequestId: pullRequestId, position: position).insert(db)
            try insertReactions(comment.reactions, of: comment.id, in: pullRequestId, db)
        }
    }
}

/// Stores the groups anyone has reacted with; the rest are left out, as they show nothing.
private func insertReactions(_ groups: [ReactionGroup], of subjectId: String, in pullRequestId: String, _ db: Database) throws {
    for group in groups where group.count > 0 {
        try ReactionRow(pullRequestId: pullRequestId, subjectId: subjectId, content: group.content.rawValue, count: group.count, viewerHasReacted: group.viewerHasReacted).insert(db)
    }
}

private struct ConversationRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversation"

    let pullRequestId: String
    let authorLogin: String?
    let authorAvatarUrl: String?
    let createdAt: Date
    let bodyHTML: String
    let body: String
    let fetchedAt: Date
    var pendingReviewId: String?
    var pendingReviewBody: String?
    var pendingReviewCommentCount: Int?
    var viewerReviewCommitOid: String?
    var viewerReviewedAt: Date?
    var viewerReviewState: String?

    var pendingReview: PendingReview? {
        pendingReviewId.map { PendingReview(id: $0, body: pendingReviewBody ?? "", commentCount: pendingReviewCommentCount ?? 0) }
    }

    var viewerReview: ViewerReview? {
        viewerReviewCommitOid.map { oid in
            ViewerReview(state: viewerReviewState.map(ReviewState.init(lenientRawValue:)) ?? .unknown, commitOid: oid, submittedAt: viewerReviewedAt)
        }
    }
}

/// A timeline item of any kind, flattened into the columns its kind uses.
private struct TimelineItemRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "timelineItem"

    let pullRequestId: String
    let id: String
    let position: Int
    let kind: String
    let date: Date
    let actorLogin: String?
    let actorAvatarUrl: String?
    var bodyHTML: String?
    var isMinimized: Bool?
    var reviewState: String?
    var commitOid: String?
    var previousOid: String?
    /// A commit's headline, the branch merged into, or the reviewer asked.
    var detail: String?
    let isSending: Bool
    let viewerCanUpdate: Bool
    let viewerCanDelete: Bool
    let isSaving: Bool

    init(_ item: TimelineItem, pullRequestId: String, position: Int) {
        self.pullRequestId = pullRequestId
        id = item.id
        self.position = position
        isSending = item.isSending
        viewerCanUpdate = item.viewerCanUpdate
        viewerCanDelete = item.viewerCanDelete
        isSaving = item.isSaving
        date = item.date
        actorLogin = item.actor?.login
        actorAvatarUrl = item.actor?.avatarURL
        switch item.event {
        case let .comment(bodyHTML, isMinimized):
            kind = "comment"
            self.bodyHTML = bodyHTML
            self.isMinimized = isMinimized
        case let .review(state, bodyHTML, _):
            kind = "review"
            reviewState = state.rawValue
            self.bodyHTML = bodyHTML
        case let .commit(oid, headline):
            kind = "commit"
            commitOid = oid
            detail = headline
        case let .forcePushed(before, after):
            kind = "forcePushed"
            previousOid = before
            commitOid = after
        case let .merged(commit, into):
            kind = "merged"
            commitOid = commit
            detail = into
        case .closed:
            kind = "closed"
        case .reopened:
            kind = "reopened"
        case .readyForReview:
            kind = "readyForReview"
        case let .reviewRequested(reviewer):
            kind = "reviewRequested"
            detail = reviewer
        }
    }

    /// Nil for a kind this version doesn't know.
    func timelineItem(comments: [ReviewCommentRow]) -> TimelineItem? {
        let event: TimelineEvent
        switch kind {
        case "comment": event = .comment(bodyHTML: bodyHTML ?? "", isMinimized: isMinimized ?? false)
        case "review": event = .review(state: ReviewState(lenientRawValue: reviewState ?? ""), bodyHTML: bodyHTML ?? "", comments: comments.map(\.comment))
        case "commit": event = .commit(oid: commitOid ?? "", headline: detail ?? "")
        case "forcePushed": event = .forcePushed(before: previousOid, after: commitOid)
        case "merged": event = .merged(commit: commitOid, into: detail ?? "")
        case "closed": event = .closed
        case "reopened": event = .reopened
        case "readyForReview": event = .readyForReview
        case "reviewRequested": event = .reviewRequested(reviewer: detail)
        default: return nil
        }
        return TimelineItem(id: id, date: date, actor: participant(actorLogin, actorAvatarUrl), event: event, isSending: isSending, viewerCanUpdate: viewerCanUpdate, viewerCanDelete: viewerCanDelete, isSaving: isSaving)
    }
}

private struct ReviewCommentRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reviewComment"

    let pullRequestId: String
    let id: String
    let reviewId: String
    let position: Int
    let bodyHTML: String
    let path: String
    let line: Int?
    let originalLine: Int?
    let diffHunk: String
    let isOutdated: Bool
    let isMinimized: Bool
    let replyToId: String?

    init(_ comment: ReviewComment, reviewId: String, pullRequestId: String, position: Int) {
        self.pullRequestId = pullRequestId
        id = comment.id
        self.reviewId = reviewId
        self.position = position
        bodyHTML = comment.bodyHTML
        path = comment.path
        line = comment.line
        originalLine = comment.originalLine
        diffHunk = comment.diffHunk
        isOutdated = comment.isOutdated
        isMinimized = comment.isMinimized
        replyToId = comment.replyTo
    }

    var comment: ReviewComment {
        ReviewComment(id: id, bodyHTML: bodyHTML, path: path, line: line, originalLine: originalLine, diffHunk: diffHunk, isOutdated: isOutdated, isMinimized: isMinimized, replyTo: replyToId)
    }
}

private struct ReviewThreadRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reviewThread"

    let pullRequestId: String
    let id: String
    let position: Int
    let isResolved: Bool
    let isOutdated: Bool
    let path: String
    let line: Int?
    let startLine: Int?
    let side: String
    let originalLine: Int?
    let originalStartLine: Int?
    let isOnFile: Bool
    let diffHunk: String
    let resolvedBy: String?
    let viewerCanReply: Bool
    let viewerCanResolve: Bool
    let viewerCanUnresolve: Bool

    init(_ thread: ReviewThread, pullRequestId: String, position: Int) {
        self.pullRequestId = pullRequestId
        id = thread.id
        self.position = position
        isResolved = thread.isResolved
        isOutdated = thread.isOutdated
        path = thread.path
        line = thread.line
        startLine = thread.startLine
        side = thread.side.rawValue
        originalLine = thread.originalLine
        originalStartLine = thread.originalStartLine
        isOnFile = thread.isOnFile
        diffHunk = thread.diffHunk
        resolvedBy = thread.resolvedBy
        viewerCanReply = thread.viewerCanReply
        viewerCanResolve = thread.viewerCanResolve
        viewerCanUnresolve = thread.viewerCanUnresolve
    }

    func thread(comments: [ThreadComment]) -> ReviewThread {
        ReviewThread(
            id: id, isResolved: isResolved, isOutdated: isOutdated, path: path, line: line, startLine: startLine,
            side: ReviewThread.Side(rawValue: side) ?? .right, originalLine: originalLine, originalStartLine: originalStartLine,
            isOnFile: isOnFile, diffHunk: diffHunk, resolvedBy: resolvedBy, viewerCanReply: viewerCanReply,
            viewerCanResolve: viewerCanResolve, viewerCanUnresolve: viewerCanUnresolve, comments: comments
        )
    }
}

private struct ThreadCommentRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "threadComment"

    let pullRequestId: String
    let id: String
    let threadId: String
    let position: Int
    let databaseId: Int?
    let authorLogin: String?
    let authorAvatarUrl: String?
    let createdAt: Date
    let bodyHTML: String
    let isMinimized: Bool
    let minimizedReason: String?
    let isPending: Bool
    let isSending: Bool
    let viewerCanUpdate: Bool
    let viewerCanDelete: Bool
    let isSaving: Bool

    init(_ comment: ThreadComment, threadId: String, pullRequestId: String, position: Int) {
        self.pullRequestId = pullRequestId
        id = comment.id
        self.threadId = threadId
        self.position = position
        databaseId = comment.databaseId
        authorLogin = comment.author?.login
        authorAvatarUrl = comment.author?.avatarURL
        createdAt = comment.createdAt
        bodyHTML = comment.bodyHTML
        isMinimized = comment.isMinimized
        minimizedReason = comment.minimizedReason
        isPending = comment.isPending
        isSending = comment.isSending
        viewerCanUpdate = comment.viewerCanUpdate
        viewerCanDelete = comment.viewerCanDelete
        isSaving = comment.isSaving
    }

    var comment: ThreadComment {
        ThreadComment(
            id: id, databaseId: databaseId, author: participant(authorLogin, authorAvatarUrl), createdAt: createdAt, bodyHTML: bodyHTML, isMinimized: isMinimized,
            minimizedReason: minimizedReason, isPending: isPending, isSending: isSending, viewerCanUpdate: viewerCanUpdate,
            viewerCanDelete: viewerCanDelete, isSaving: isSaving
        )
    }
}

/// The people who reacted to one thing with one reaction.
private struct ReactionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reaction"

    let pullRequestId: String
    let subjectId: String
    let content: String
    let count: Int
    let viewerHasReacted: Bool

    /// Nil for a reaction this version doesn't know.
    var group: ReactionGroup? {
        Reaction(rawValue: content).map { ReactionGroup(content: $0, count: count, viewerHasReacted: viewerHasReacted) }
    }
}

private struct CheckContextRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "checkContext"

    let pullRequestId: String
    let position: Int
    let name: String
    let status: String
    let description: String?
    let url: String?
}

/// A reviewer asked, or one who has reviewed with their latest review's state.
private struct ReviewerRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversationReviewer"
    static let request = "request"
    static let review = "review"

    let pullRequestId: String
    let role: String
    let position: Int
    let kind: String
    let nodeId: String?
    let login: String
    let name: String?
    let avatarUrl: String?
    var reviewState: String?
    var submittedAt: Date?

    init(_ reviewer: Reviewer, role: String, pullRequestId: String, position: Int) {
        self.pullRequestId = pullRequestId
        self.role = role
        self.position = position
        kind = reviewer.kind.rawValue
        nodeId = reviewer.nodeId
        login = reviewer.login
        name = reviewer.name
        avatarUrl = reviewer.avatarURL
    }

    /// Nil for a kind this version doesn't know.
    var reviewer: Reviewer? {
        Reviewer.Kind(rawValue: kind).map { Reviewer(kind: $0, nodeId: nodeId, login: login, name: name, avatarURL: avatarUrl) }
    }

    var latestReview: LatestReview? {
        reviewer.map { LatestReview(reviewer: $0, state: ReviewState(lenientRawValue: reviewState ?? ""), submittedAt: submittedAt) }
    }
}

private func participant(_ login: String?, _ avatarURL: String?) -> Participant? {
    login.map { Participant(login: $0, avatarURL: avatarURL) }
}
