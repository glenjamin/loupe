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
    /// The viewer's review not yet submitted, if they have one; only they can see it.
    public var pendingReview: PendingReview?

    public init(author: Participant?, createdAt: Date, bodyHTML: String, body: String = "", items: [TimelineItem], threads: [ReviewThread], checks: [CheckContext], reviewRequests: [Reviewer] = [], latestReviews: [LatestReview] = [], pendingReview: PendingReview? = nil) {
        self.author = author
        self.createdAt = createdAt
        self.bodyHTML = bodyHTML
        self.body = body
        self.items = items
        self.threads = threads
        self.checks = checks
        self.reviewRequests = reviewRequests
        self.latestReviews = latestReviews
        self.pendingReview = pendingReview
    }
}

/// The viewer's review of a PR, started and not yet submitted: its comments show only to them
/// until it is.
public struct PendingReview: Sendable, Equatable {
    public var id: String
    /// The summary as last saved with the review, in markdown.
    public var body: String
    public var commentCount: Int

    public init(id: String, body: String, commentCount: Int) {
        self.id = id
        self.body = body
        self.commentCount = commentCount
    }
}

/// What submitting a review says of the PR, in GitHub's terms.
public enum ReviewEvent: String, Sendable, CaseIterable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
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
    /// The last line the thread is on in the current diff; nil once outdated, or for a thread
    /// on the whole file.
    public var line: Int?
    /// The first line of a thread on several; nil or the same as `line` for one line.
    public var startLine: Int?
    public var side: Side
    /// Where the thread was on the commit it was made on, which outlives an outdated thread.
    public var originalLine: Int?
    public var originalStartLine: Int?
    /// On the file as a whole rather than on lines of it.
    public var isOnFile: Bool
    /// The diff around the first comment, ending on its line, as GitHub keeps it.
    public var diffHunk: String
    /// Who resolved it, if it's resolved and GitHub still knows them.
    public var resolvedBy: String?
    public var viewerCanReply: Bool
    public var viewerCanResolve: Bool
    public var viewerCanUnresolve: Bool
    /// The first comment, then the replies, oldest first.
    public var comments: [ThreadComment]

    /// Which version of the file a thread's lines are numbered in: RIGHT is the PR's head,
    /// LEFT its base, as for a comment on a deleted line.
    public enum Side: String, Sendable {
        case left = "LEFT"
        case right = "RIGHT"
    }

    public init(
        id: String, isResolved: Bool, isOutdated: Bool, path: String, line: Int?, startLine: Int? = nil, side: Side = .right,
        originalLine: Int? = nil, originalStartLine: Int? = nil, isOnFile: Bool = false, diffHunk: String = "", resolvedBy: String? = nil,
        viewerCanReply: Bool = false, viewerCanResolve: Bool = false, viewerCanUnresolve: Bool = false, comments: [ThreadComment]
    ) {
        self.id = id
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.path = path
        self.line = line
        self.startLine = startLine
        self.side = side
        self.originalLine = originalLine
        self.originalStartLine = originalStartLine
        self.isOnFile = isOnFile
        self.diffHunk = diffHunk
        self.resolvedBy = resolvedBy
        self.viewerCanReply = viewerCanReply
        self.viewerCanResolve = viewerCanResolve
        self.viewerCanUnresolve = viewerCanUnresolve
        self.comments = comments
    }

    /// The lines the thread covers, first to last: in the current diff, or where it was made
    /// once outdated. Nil for a thread on the whole file.
    public var lines: ClosedRange<Int>? {
        guard let last = line ?? originalLine else { return nil }
        let first = (line != nil ? startLine : originalStartLine) ?? last
        return min(first, last)...last
    }

    /// Started in the viewer's pending review, so no one else sees it yet.
    public var isPending: Bool {
        comments.first?.isPending == true
    }
}

public struct ThreadComment: Sendable, Equatable, Identifiable {
    public var id: String
    /// The REST API's id for the comment, which replying to its thread names.
    public var databaseId: Int?
    public var author: Participant?
    public var createdAt: Date
    public var bodyHTML: String
    public var isMinimized: Bool
    /// Why it was hidden, in GitHub's words, such as `outdated` or `resolved`.
    public var minimizedReason: String?
    /// Part of the viewer's pending review, not yet submitted.
    public var isPending: Bool

    public init(id: String, databaseId: Int? = nil, author: Participant?, createdAt: Date, bodyHTML: String, isMinimized: Bool, minimizedReason: String? = nil, isPending: Bool = false) {
        self.id = id
        self.databaseId = databaseId
        self.author = author
        self.createdAt = createdAt
        self.bodyHTML = bodyHTML
        self.isMinimized = isMinimized
        self.minimizedReason = minimizedReason
        self.isPending = isPending
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
