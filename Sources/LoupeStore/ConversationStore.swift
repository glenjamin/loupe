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
            return Conversation(
                author: participant(row.authorLogin, row.authorAvatarUrl),
                createdAt: row.createdAt,
                bodyHTML: row.bodyHTML,
                items: try TimelineItemRow.filter(byPR).order(Column("position")).fetchAll(db).compactMap { item in
                    item.timelineItem(comments: comments[item.id] ?? [])
                },
                threads: try ReviewThreadRow.filter(byPR).order(Column("position")).fetchAll(db).map { thread in
                    ReviewThread(id: thread.id, isResolved: thread.isResolved, isOutdated: thread.isOutdated, path: thread.path, line: thread.line, comments: (threadComments[thread.id] ?? []).map(\.comment))
                },
                checks: try CheckContextRow.filter(byPR).order(Column("position")).fetchAll(db).map { check in
                    CheckContext(name: check.name, status: CheckStatus(rawValue: check.status) ?? .neutral, description: check.description, url: check.url)
                },
                reviewRequests: reviewers.filter { $0.role == ReviewerRow.request }.compactMap(\.reviewer),
                latestReviews: reviewers.filter { $0.role == ReviewerRow.review }.compactMap(\.latestReview)
            )
        }
    }

    /// Makes the PR's stored conversation exactly `conversation`, as GitHub returned it.
    public func replaceConversation(of pullRequestId: String, with conversation: Conversation, fetchedAt: Date) async throws {
        try await database.write { db in
            for table in ["timelineItem", "reviewComment", "reviewThread", "threadComment", "checkContext", "conversationReviewer"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE pullRequestId = ?", arguments: [pullRequestId])
            }
            try ConversationRow(
                pullRequestId: pullRequestId,
                authorLogin: conversation.author?.login,
                authorAvatarUrl: conversation.author?.avatarURL,
                createdAt: conversation.createdAt,
                bodyHTML: conversation.bodyHTML,
                fetchedAt: fetchedAt
            ).upsert(db)
            for (position, item) in conversation.items.enumerated() {
                try TimelineItemRow(item, pullRequestId: pullRequestId, position: position).insert(db)
                guard case let .review(_, _, comments) = item.event else { continue }
                for (position, comment) in comments.enumerated() {
                    try ReviewCommentRow(comment, reviewId: item.id, pullRequestId: pullRequestId, position: position).insert(db)
                }
            }
            for (position, thread) in conversation.threads.enumerated() {
                try ReviewThreadRow(pullRequestId: pullRequestId, id: thread.id, position: position, isResolved: thread.isResolved, isOutdated: thread.isOutdated, path: thread.path, line: thread.line).insert(db)
                for (position, comment) in thread.comments.enumerated() {
                    try ThreadCommentRow(comment, threadId: thread.id, pullRequestId: pullRequestId, position: position).insert(db)
                }
            }
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

private struct ConversationRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversation"

    let pullRequestId: String
    let authorLogin: String?
    let authorAvatarUrl: String?
    let createdAt: Date
    let bodyHTML: String
    let fetchedAt: Date
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

    init(_ item: TimelineItem, pullRequestId: String, position: Int) {
        self.pullRequestId = pullRequestId
        id = item.id
        self.position = position
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
        return TimelineItem(id: id, date: date, actor: participant(actorLogin, actorAvatarUrl), event: event)
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
}

private struct ThreadCommentRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "threadComment"

    let pullRequestId: String
    let id: String
    let threadId: String
    let position: Int
    let authorLogin: String?
    let authorAvatarUrl: String?
    let createdAt: Date
    let bodyHTML: String
    let isMinimized: Bool

    init(_ comment: ThreadComment, threadId: String, pullRequestId: String, position: Int) {
        self.pullRequestId = pullRequestId
        id = comment.id
        self.threadId = threadId
        self.position = position
        authorLogin = comment.author?.login
        authorAvatarUrl = comment.author?.avatarURL
        createdAt = comment.createdAt
        bodyHTML = comment.bodyHTML
        isMinimized = comment.isMinimized
    }

    var comment: ThreadComment {
        ThreadComment(id: id, author: participant(authorLogin, authorAvatarUrl), createdAt: createdAt, bodyHTML: bodyHTML, isMinimized: isMinimized)
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
