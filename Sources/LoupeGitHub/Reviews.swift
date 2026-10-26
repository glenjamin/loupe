import Foundation
import LoupeModel

/// A PR's review threads and the viewer's pending review, as fetched together.
public struct ReviewThreads: Sendable, Equatable {
    public var threads: [ReviewThread]
    public var pendingReview: PendingReview?
}

/// A comment on one line, as a review's new thread.
public struct DraftThread: Sendable, Equatable {
    public var path: String
    /// A file line number on `side`.
    public var line: Int
    /// `LEFT` for the base, `RIGHT` for the head.
    public var side: String
    /// The first line and its side, for a comment on several lines.
    public var startLine: Int?
    public var startSide: String?
    public var body: String

    public init(path: String, line: Int, side: String, startLine: Int? = nil, startSide: String? = nil, body: String) {
        self.path = path
        self.line = line
        self.side = side
        self.startLine = startLine
        self.startSide = startSide
        self.body = body
    }
}

/// A review as GitHub answers starting or submitting it.
public struct PostedReview: Sendable, Equatable {
    public var id: String
    public var state: ReviewState
    public var bodyHTML: String
    /// When it was submitted, or started for one still pending.
    public var date: Date
    public var author: Participant?
    /// The comment it started with, for a review started holding one.
    public var comments: [ThreadComment]

    public init(id: String, state: ReviewState, bodyHTML: String, date: Date, author: Participant?, comments: [ThreadComment]) {
        self.id = id
        self.state = state
        self.bodyHTML = bodyHTML
        self.date = date
        self.author = author
        self.comments = comments
    }
}

/// A thread added to a pending review, with its one comment, as GitHub answers it.
public struct PostedThread: Sendable, Equatable {
    public var id: String
    public var comment: ThreadComment

    public init(id: String, comment: ThreadComment) {
        self.id = id
        self.comment = comment
    }
}

extension GitHubClient {
    /// Starts the viewer's pending review of the PR with `pullRequestId`, holding `threads`,
    /// when `event` is nil; with an event, submits a review at once. `commitId` is the commit
    /// the review is of, whose line numbers the threads use.
    @discardableResult
    public func addReview(toPullRequest pullRequestId: String, commitId: String?, body: String?, event: ReviewEvent?, threads: [DraftThread]) async throws -> PostedReview {
        let input = AddReviewInput(pullRequestId: pullRequestId, commitOID: commitId, body: body, event: event?.rawValue, threads: threads.map(ThreadInput.init))
        let response: AddReviewResponse = try await query(Self.addReviewMutation, variables: Input(input: input))
        guard let review = response.addPullRequestReview?.pullRequestReview else { throw GitHubError.graphQL(["GitHub didn't return the review"]) }
        return review.posted
    }

    /// Adds a comment on a line to the viewer's pending review with `reviewId`, as a new thread.
    @discardableResult
    public func addThread(_ thread: DraftThread, toReview reviewId: String) async throws -> PostedThread {
        let input = AddThreadInput(
            pullRequestReviewId: reviewId, path: thread.path, line: thread.line, side: thread.side, startLine: thread.startLine, startSide: thread.startSide, body: thread.body
        )
        let response: AddThreadResponse = try await query(Self.addThreadMutation, variables: Input(input: input))
        guard let thread = response.addPullRequestReviewThread?.thread, let comment = thread.comments.nodes.first else {
            throw GitHubError.graphQL(["GitHub didn't return the comment"])
        }
        return PostedThread(id: thread.id, comment: comment.comment)
    }

    /// Adds a comment on a line of one commit to the viewer's pending review with `reviewId`, as
    /// github.com does from a PR's commit view. GraphQL's only mutation that takes a commit,
    /// which GitHub has marked for removal; it places the comment by `position`, as
    /// `diffPosition` finds it.
    @discardableResult
    public func addCommitComment(_ body: String, path: String, position: Int, commitId: String, toReview reviewId: String) async throws -> ThreadComment {
        let input = AddCommentInput(pullRequestReviewId: reviewId, commitOID: commitId, path: path, position: position, body: body)
        let response: AddCommentResponse = try await query(Self.addCommitCommentMutation, variables: Input(input: input))
        guard let comment = response.addPullRequestReviewComment?.comment else { throw GitHubError.graphQL(["GitHub didn't return the comment"]) }
        return comment.comment
    }

    /// Where `line` on `side` of `path` sits in GitHub's diff of the file from `base` to
    /// `commitId`, counted as the lines below its first hunk header, as GitHub's `position` is;
    /// nil when that diff doesn't show the line. GitHub's own diff, from its compare, as it can
    /// draw hunks differently from git.
    public func diffPosition(ofLine line: Int, side: String, path: String, from base: String, to commitId: String, in repository: String) async throws -> Int? {
        // The first page lists every changed file, however many commits there are.
        let body = try await rest("GET", path: "/repos/\(repository)/compare/\(base)...\(commitId)?per_page=1")
        let comparison = try JSONDecoder().decode(Comparison.self, from: body)
        guard let patch = comparison.files.first(where: { $0.filename == path })?.patch else { return nil }
        return position(ofLine: line, side: side, inPatch: patch)
    }

    /// Submits the viewer's pending review with `reviewId`, its summary replaced by `body`.
    @discardableResult
    public func submitReview(_ reviewId: String, event: ReviewEvent, body: String) async throws -> PostedReview {
        let input = SubmitReviewInput(pullRequestReviewId: reviewId, event: event.rawValue, body: body)
        let response: SubmitReviewResponse = try await query(Self.submitReviewMutation, variables: Input(input: input))
        guard let review = response.submitPullRequestReview?.pullRequestReview else { throw GitHubError.graphQL(["GitHub didn't return the review"]) }
        return review.posted
    }

    /// Abandons the viewer's pending review with `reviewId`, and its comments with it.
    public func deleteReview(_ reviewId: String) async throws {
        let _: IgnoredPayload = try await query(Self.deleteReviewMutation, variables: Input(input: DeleteReviewInput(pullRequestReviewId: reviewId)))
    }

    /// Deletes the review comment with node id `commentId`, such as one of the viewer's pending
    /// review's; a thread left with no comments goes with it.
    public func deleteReviewComment(_ commentId: String) async throws {
        let _: IgnoredPayload = try await query(Self.deleteReviewCommentMutation, variables: Input(input: DeleteReviewCommentInput(id: commentId)))
    }

    static let addReviewMutation = """
        mutation($input: AddPullRequestReviewInput!) {
          addPullRequestReview(input: $input) { pullRequestReview { ...PostedReview } }
        }
        """ + postedReviewFragment + postedCommentFragment

    static let addThreadMutation = """
        mutation($input: AddPullRequestReviewThreadInput!) {
          addPullRequestReviewThread(input: $input) { thread { id comments(first: 1) { nodes { ...PostedComment } } } }
        }
        """ + postedCommentFragment

    static let addCommitCommentMutation = """
        mutation($input: AddPullRequestReviewCommentInput!) {
          addPullRequestReviewComment(input: $input) { comment { ...PostedComment } }
        }
        """ + postedCommentFragment

    static let submitReviewMutation = """
        mutation($input: SubmitPullRequestReviewInput!) {
          submitPullRequestReview(input: $input) { pullRequestReview { ...PostedReview } }
        }
        """ + postedReviewFragment + postedCommentFragment

    static let deleteReviewMutation = """
        mutation($input: DeletePullRequestReviewInput!) {
          deletePullRequestReview(input: $input) { pullRequestReview { id } }
        }
        """

    static let deleteReviewCommentMutation = """
        mutation($input: DeletePullRequestReviewCommentInput!) {
          deletePullRequestReviewComment(input: $input) { pullRequestReview { id } }
        }
        """

    /// What the timeline shows of a review, and the comment a review started holding.
    static let postedReviewFragment = """

        fragment PostedReview on PullRequestReview {
          id state bodyHTML createdAt submittedAt author { login avatarUrl }
          comments(first: 1) { nodes { ...PostedComment } }
        }
        """

    /// What a thread shows of a comment.
    static let postedCommentFragment = """

        fragment PostedComment on PullRequestReviewComment {
          id databaseId bodyHTML createdAt state viewerCanUpdate viewerCanDelete author { login avatarUrl }
        }
        """
}

private struct Input<Value: Encodable & Sendable>: Encodable, Sendable {
    let input: Value
}

/// Optional fields left out when nil, as GitHub takes a missing `event` to mean pending.
private struct AddReviewInput: Encodable, Sendable {
    let pullRequestId: String
    let commitOID: String?
    let body: String?
    let event: String?
    let threads: [ThreadInput]
}

private struct ThreadInput: Encodable, Sendable {
    let path: String
    let line: Int
    let side: String
    let startLine: Int?
    let startSide: String?
    let body: String

    init(_ thread: DraftThread) {
        path = thread.path
        line = thread.line
        side = thread.side
        startLine = thread.startLine
        startSide = thread.startSide
        body = thread.body
    }
}

private struct AddThreadInput: Encodable, Sendable {
    let pullRequestReviewId: String
    let path: String
    let line: Int
    let side: String
    let startLine: Int?
    let startSide: String?
    let body: String
}

private struct AddCommentInput: Encodable, Sendable {
    let pullRequestReviewId: String
    let commitOID: String
    let path: String
    let position: Int
    let body: String
}

private struct SubmitReviewInput: Encodable, Sendable {
    let pullRequestReviewId: String
    let event: String
    let body: String
}

private struct DeleteReviewInput: Encodable, Sendable {
    let pullRequestReviewId: String
}

private struct DeleteReviewCommentInput: Encodable, Sendable {
    let id: String
}

private struct AddReviewResponse: Decodable {
    let addPullRequestReview: Payload?

    struct Payload: Decodable {
        let pullRequestReview: ReviewNode?
    }
}

private struct AddThreadResponse: Decodable {
    let addPullRequestReviewThread: Payload?

    struct Payload: Decodable {
        let thread: Thread?
    }

    struct Thread: Decodable {
        let id: String
        let comments: Nodes<CommentNode>
    }
}

private struct AddCommentResponse: Decodable {
    let addPullRequestReviewComment: Payload?

    struct Payload: Decodable {
        let comment: CommentNode?
    }
}

/// A REST compare's changed files, each with its patch unless GitHub leaves out one too big.
private struct Comparison: Decodable {
    let files: [File]

    struct File: Decodable {
        let filename: String
        let patch: String?
    }
}

private struct SubmitReviewResponse: Decodable {
    let submitPullRequestReview: Payload?

    struct Payload: Decodable {
        let pullRequestReview: ReviewNode?
    }
}

/// A review as the `PostedReview` fragment returns it.
private struct ReviewNode: Decodable {
    let id: String
    let state: ReviewState
    let bodyHTML: String
    let createdAt: Date
    let submittedAt: Date?
    let author: AuthorNode?
    let comments: Nodes<CommentNode>

    var posted: PostedReview {
        PostedReview(id: id, state: state, bodyHTML: bodyHTML, date: submittedAt ?? createdAt, author: author?.participant, comments: comments.nodes.map(\.comment))
    }
}

/// A comment as the `PostedComment` fragment returns it.
private struct CommentNode: Decodable {
    let id: String
    let databaseId: Int?
    let bodyHTML: String
    let createdAt: Date
    let state: String?
    let viewerCanUpdate: Bool?
    let viewerCanDelete: Bool?
    let author: AuthorNode?

    var comment: ThreadComment {
        ThreadComment(
            id: id, databaseId: databaseId, author: author?.participant, createdAt: createdAt, bodyHTML: bodyHTML, isMinimized: false,
            isPending: state == "PENDING", viewerCanUpdate: viewerCanUpdate ?? false, viewerCanDelete: viewerCanDelete ?? false
        )
    }
}

private struct AuthorNode: Decodable {
    let login: String
    let avatarUrl: String?

    var participant: Participant {
        Participant(login: login, avatarURL: avatarUrl)
    }
}

private struct Nodes<Node: Decodable>: Decodable {
    let nodes: [Node]
}

/// For a mutation whose payload isn't needed; its errors still come through the envelope.
private struct IgnoredPayload: Decodable {}

/// The 1-based count of `patch`'s lines, after its first hunk header, down to `line` on `side`.
private func position(ofLine line: Int, side: String, inPatch patch: String) -> Int? {
    var (position, old, new) = (0, 0, 0)
    var started = false
    for row in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        if let header = row.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)/) {
            if started { position += 1 }
            started = true
            (old, new) = (Int(header.1) ?? 0, Int(header.2) ?? 0)
            continue
        }
        guard started else { continue }
        position += 1
        switch row.first {
        case "-":
            if side == "LEFT", old == line { return position }
            old += 1
        case "+":
            if side == "RIGHT", new == line { return position }
            new += 1
        case "\\":
            continue
        default:
            if (side == "LEFT" ? old : new) == line { return position }
            old += 1
            new += 1
        }
    }
    return nil
}
