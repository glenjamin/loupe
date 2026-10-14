import Foundation

/// A PR's conversation as github.com shows it: the description, then what happened in order,
/// its review threads and its head commit's CI. Bodies are GitHub's own rendered HTML.
public struct Conversation: Sendable, Equatable {
    public var author: Participant?
    public var createdAt: Date
    public var bodyHTML: String
    /// The description as its author wrote it, in GitHub-flavoured markdown.
    public var body: String
    /// In GitHub's order, oldest first.
    public var items: [TimelineItem]
    /// Every review thread with all its comments, as a review in the timeline holds only the
    /// comments made with it, not the replies made later.
    public var threads: [ReviewThread]
    public var checks: [CheckContext]
    /// Who is asked to review and hasn't since, in GitHub's order.
    public var reviewRequests: [Reviewer]
    /// Each reviewer's most recent submitted review, in GitHub's order.
    public var latestReviews: [LatestReview]

    public init(author: Participant?, createdAt: Date, bodyHTML: String, body: String = "", items: [TimelineItem], threads: [ReviewThread], checks: [CheckContext], reviewRequests: [Reviewer] = [], latestReviews: [LatestReview] = []) {
        self.author = author
        self.createdAt = createdAt
        self.bodyHTML = bodyHTML
        self.body = body
        self.items = items
        self.threads = threads
        self.checks = checks
        self.reviewRequests = reviewRequests
        self.latestReviews = latestReviews
    }
}

/// A person, team or bot who can be asked to review.
public struct Reviewer: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case user
        case team
        case bot
    }

    public var kind: Kind
    /// GitHub's node id, which a review request names. Nil if GitHub didn't give one.
    public var nodeId: String?
    /// A user's or bot's login, or a team's `org/slug`.
    public var login: String
    /// A team's name, or a user's full name if they've given one.
    public var name: String?
    public var avatarURL: String?

    public init(kind: Kind, nodeId: String?, login: String, name: String? = nil, avatarURL: String? = nil) {
        self.kind = kind
        self.nodeId = nodeId
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }

    public var id: String { "\(kind.rawValue):\(login)" }

    /// How the reviewer is shown: a team by its name, anyone else by their login.
    public var displayName: String {
        kind == .team ? name ?? login : login
    }
}

/// A reviewer's most recent submitted review.
public struct LatestReview: Sendable, Equatable {
    public var reviewer: Reviewer
    public var state: ReviewState
    public var submittedAt: Date?

    public init(reviewer: Reviewer, state: ReviewState, submittedAt: Date?) {
        self.reviewer = reviewer
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// Someone who took part. Deleted accounts have no participant at all.
public struct Participant: Sendable, Equatable {
    public var login: String
    public var avatarURL: String?

    public init(login: String, avatarURL: String?) {
        self.login = login
        self.avatarURL = avatarURL
    }
}

public struct TimelineItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var date: Date
    /// Who did it: the commenter, reviewer, pusher or commit author.
    public var actor: Participant?
    public var event: TimelineEvent

    public init(id: String, date: Date, actor: Participant?, event: TimelineEvent) {
        self.id = id
        self.date = date
        self.actor = actor
        self.event = event
    }
}

public enum TimelineEvent: Sendable, Equatable {
    case comment(bodyHTML: String, isMinimized: Bool)
    case review(state: ReviewState, bodyHTML: String, comments: [ReviewComment])
    case commit(oid: String, headline: String)
    case forcePushed(before: String?, after: String?)
    case merged(commit: String?, into: String)
    case closed
    case reopened
    case readyForReview
    /// The login or team slug asked, if GitHub still knows them.
    case reviewRequested(reviewer: String?)
}

public enum ReviewState: String, Sendable, LenientEnum {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case dismissed = "DISMISSED"
    /// The viewer's own review, not yet submitted.
    case pending = "PENDING"
    case unknown
}

/// A comment made on a line as part of a review.
public struct ReviewComment: Sendable, Equatable, Identifiable {
    public var id: String
    public var bodyHTML: String
    public var path: String
    /// Nil once outdated, when only `originalLine` is known.
    public var line: Int?
    public var originalLine: Int?
    /// The diff around the comment, ending on its line.
    public var diffHunk: String
    public var isOutdated: Bool
    public var isMinimized: Bool
    /// The comment this replies to, for a reply.
    public var replyTo: String?

    public init(id: String, bodyHTML: String, path: String, line: Int?, originalLine: Int?, diffHunk: String, isOutdated: Bool, isMinimized: Bool, replyTo: String?) {
        self.id = id
        self.bodyHTML = bodyHTML
        self.path = path
        self.line = line
        self.originalLine = originalLine
        self.diffHunk = diffHunk
        self.isOutdated = isOutdated
        self.isMinimized = isMinimized
        self.replyTo = replyTo
    }
}

public struct ReviewThread: Sendable, Equatable, Identifiable {
    public var id: String
    public var isResolved: Bool
    public var isOutdated: Bool
    public var path: String
    public var line: Int?
    /// The first comment, then the replies, oldest first.
    public var comments: [ThreadComment]

    public init(id: String, isResolved: Bool, isOutdated: Bool, path: String, line: Int?, comments: [ThreadComment]) {
        self.id = id
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.path = path
        self.line = line
        self.comments = comments
    }
}

public struct ThreadComment: Sendable, Equatable, Identifiable {
    public var id: String
    public var author: Participant?
    public var createdAt: Date
    public var bodyHTML: String
    public var isMinimized: Bool

    public init(id: String, author: Participant?, createdAt: Date, bodyHTML: String, isMinimized: Bool) {
        self.id = id
        self.author = author
        self.createdAt = createdAt
        self.bodyHTML = bodyHTML
        self.isMinimized = isMinimized
    }
}

/// One CI status or check run on the head commit.
public struct CheckContext: Sendable, Hashable {
    public var name: String
    public var status: CheckStatus
    public var description: String?
    public var url: String?

    public init(name: String, status: CheckStatus, description: String?, url: String?) {
        self.name = name
        self.status = status
        self.description = description
        self.url = url
    }
}

/// A check's outcome, the same whether it came from a commit status or a check run.
public enum CheckStatus: String, Sendable {
    case success
    case failure
    case pending
    /// Finished without passing or failing: neutral, skipped or cancelled.
    case neutral
}
