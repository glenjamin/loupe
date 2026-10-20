import Foundation
import GRDB
import LoupeModel

/// The local copy of the start screen's PRs, so the app has something to show before (or
/// without) reaching GitHub.
public struct PullRequestStore: Sendable {
    let database: any DatabaseWriter

    /// Opens (creating if needed) the database at `url`, creating its directory too.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(database: DatabasePool(path: url.path(percentEncoded: false)))
    }

    /// A database that lives only as long as this store.
    public static func inMemory() throws -> PullRequestStore {
        try PullRequestStore(database: DatabaseQueue())
    }

    /// `~/Library/Application Support/Loupe/loupe.sqlite`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "Loupe", "loupe.sqlite")
    }

    private init(database: any DatabaseWriter) throws {
        self.database = database
        try Self.migrator.migrate(database)
    }

    /// The stored lists, as of their last successful refresh.
    public func snapshot() throws -> PullRequestSnapshot {
        try database.read(Self.snapshot)
    }

    /// Makes `list` exactly `pullRequests`, as GitHub returned them at `refreshedAt`: PRs that
    /// stopped appearing leave the list, and the rest are inserted or updated.
    @discardableResult
    public func replace(_ list: PullRequestList, with pullRequests: [PullRequestSummary], refreshedAt: Date) async throws -> PullRequestSnapshot {
        try await database.write { db in
            try Self.upsert(pullRequests, into: list, at: refreshedAt, db)
            try ListMembership
                .filter(Column("list") == list.rawValue && !pullRequests.map(\.id).contains(Column("pullRequestId")))
                .deleteAll(db)
            try Self.deleteUnlisted(db)
            try ListRefresh(list: list.rawValue, refreshedAt: refreshedAt).upsert(db)
            return try Self.snapshot(db)
        }
    }

    /// Adds or updates `pullRequests` in `list`, as changes GitHub reported since its last
    /// refresh, and records `refreshedAt` as the time to ask for changes since next. PRs not
    /// reported are unchanged, so they stay.
    @discardableResult
    public func merge(_ list: PullRequestList, with pullRequests: [PullRequestSummary], refreshedAt: Date) async throws -> PullRequestSnapshot {
        try await database.write { db in
            try Self.upsert(pullRequests, into: list, at: refreshedAt, db)
            try ListRefresh(list: list.rawValue, refreshedAt: refreshedAt).upsert(db)
            return try Self.snapshot(db)
        }
    }

    /// Takes the PRs with `ids` out of `list`, leaving its refresh time alone.
    @discardableResult
    public func remove(_ ids: [String], from list: PullRequestList) async throws -> PullRequestSnapshot {
        try await database.write { db in
            try ListMembership
                .filter(Column("list") == list.rawValue && ids.contains(Column("pullRequestId")))
                .deleteAll(db)
            try Self.deleteUnlisted(db)
            return try Self.snapshot(db)
        }
    }

    /// Stores the PR and puts it in each of `lists`, as looking it up showed it belongs there
    /// before their searches have. Their refresh times are left alone, so the next refresh asks
    /// for changes since the last one as before, and only a full load can take it out unseen.
    @discardableResult
    public func add(_ pullRequest: PullRequestSummary, to lists: [PullRequestList], at confirmedAt: Date) async throws -> PullRequestSnapshot {
        try await database.write { db in
            try Self.upsert(pullRequest, db)
            for list in lists {
                try ListMembership(list: list.rawValue, pullRequestId: pullRequest.id, confirmedAt: confirmedAt).upsert(db)
            }
            return try Self.snapshot(db)
        }
    }

    /// Updates the stored rows of `pullRequests`, as looked up directly rather than through a
    /// list, leaving which lists they're in alone. PRs no longer stored are left out, as nothing
    /// shows them.
    @discardableResult
    public func update(_ pullRequests: [PullRequestSummary]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for pullRequest in pullRequests {
                guard let stored = try PullRequestRow.fetchOne(db, key: pullRequest.id) else { continue }
                try PullRequestRow(pullRequest, keepingLookupsFrom: stored).update(db)
            }
            return try Self.snapshot(db)
        }
    }

    /// Stores `pullRequests`, the PRs around listed ones in their stacks, whether or not they're
    /// in a list, leaving which lists they're in alone. Those no longer connected through an open
    /// stack to a listed PR or an open tab are let go, merged and closed ones among them.
    @discardableResult
    public func storeStackNeighbours(_ pullRequests: [PullRequestSummary]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for pullRequest in pullRequests {
                try Self.upsert(pullRequest, db)
            }
            try Self.deleteUnlisted(db)
            return try Self.snapshot(db)
        }
    }

    /// Replaces the stored checks, mergeability, merge state and review decision of each PR in
    /// `statuses`, keyed by id, with those last looked up. PRs no longer stored are left out, as
    /// nothing shows them.
    @discardableResult
    public func updateStatuses(_ statuses: [String: PullRequestStatus]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for (id, status) in statuses where try PullRequestRow.exists(db, key: id) {
                try db.execute(
                    sql: "UPDATE pullRequest SET checkState = ?, mergeable = ?, mergeStateStatus = ?, reviewDecision = ? WHERE id = ?",
                    arguments: [status.checks?.rawValue, status.mergeable.rawValue, status.mergeStateStatus.rawValue, status.reviewDecision?.rawValue, id]
                )
                try PullRequestCheckRow.filter(Column("pullRequestId") == id).deleteAll(db)
                for (position, check) in status.checkContexts.enumerated() {
                    try PullRequestCheckRow(pullRequestId: id, position: position, check).insert(db)
                }
            }
            return try Self.snapshot(db)
        }
    }

    /// Records when the viewer was last asked to review each PR in `requestedAt`, keyed by id,
    /// nil where GitHub showed no such request. PRs no longer stored are left out.
    @discardableResult
    public func updateReviewRequestTimes(_ requestedAt: [String: Date?]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for (id, date) in requestedAt {
                try db.execute(sql: "UPDATE pullRequest SET reviewRequestedAt = ? WHERE id = ?", arguments: [date, id])
            }
            return try Self.snapshot(db)
        }
    }

    /// Records when the viewer was first asked to review each PR in `requestedAt`, keyed by id,
    /// nil where GitHub showed no such request. PRs no longer stored are left out.
    @discardableResult
    public func updateFirstReviewRequestTimes(_ requestedAt: [String: Date?]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for (id, date) in requestedAt {
                try db.execute(sql: "UPDATE pullRequest SET firstReviewRequestedAt = ? WHERE id = ?", arguments: [date, id])
            }
            return try Self.snapshot(db)
        }
    }

    /// Records the head each PR in `commits`, keyed by id, had when its newest standing request
    /// for changes was made, nil where there's none. PRs no longer stored are left out.
    @discardableResult
    public func updateChangesRequestedCommits(_ commits: [String: String?]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for (id, oid) in commits {
                try db.execute(sql: "UPDATE pullRequest SET changesRequestedCommitOid = ? WHERE id = ?", arguments: [oid, id])
            }
            return try Self.snapshot(db)
        }
    }

    /// Replaces who each PR in `reviewers`, keyed by id, waits on for a review. PRs no longer
    /// stored are left out.
    @discardableResult
    public func updateRequestedReviewers(_ reviewers: [String: [RequestedReviewer]]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for (id, requested) in reviewers {
                let json = String(decoding: try JSONEncoder().encode(requested.map(StoredReviewer.init)), as: UTF8.self)
                try db.execute(sql: "UPDATE pullRequest SET requestedReviewers = ? WHERE id = ?", arguments: [json, id])
            }
            return try Self.snapshot(db)
        }
    }

    /// Records the viewer's latest approval or request for changes on each PR in `reviews`,
    /// keyed by id, with when and on which head, nil where they've given neither. PRs no longer
    /// stored are left out.
    @discardableResult
    public func updateViewerReviews(_ reviews: [String: ReviewVerdict?]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for (id, review) in reviews {
                try db.execute(
                    sql: "UPDATE pullRequest SET viewerReview = ?, viewerReviewedAt = ?, viewerReviewCommitOid = ? WHERE id = ?",
                    arguments: [review?.state.rawValue, review?.submittedAt, review?.commitOid, id]
                )
            }
            return try Self.snapshot(db)
        }
    }

    /// Records the viewer's latest submitted review of any kind on each PR in `reviews`, keyed
    /// by id, with what's happened since, nil where they haven't reviewed it. PRs no longer
    /// stored are left out.
    @discardableResult
    public func updateViewerLatestReviews(_ reviews: [String: ViewerLatestReview?]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for (id, review) in reviews {
                try db.execute(
                    sql: """
                        UPDATE pullRequest SET viewerLatestReviewState = ?, viewerLatestReviewedAt = ?, viewerLatestReviewCommitOid = ?,
                            commitsSinceViewerReview = ?, lastCommittedAt = ?, forcePushedSinceViewerReviewAt = ?
                        WHERE id = ?
                        """,
                    arguments: [review?.state.rawValue, review?.submittedAt, review?.commitOid, review?.commitsSince, review?.lastCommittedAt, review?.forcePushedAt, id]
                )
            }
            return try Self.snapshot(db)
        }
    }

    /// The signed-in user's GitHub login, once it's been looked up.
    public func viewerLogin() throws -> String? {
        try database.read { db in try Setting.fetchOne(db, key: Setting.viewerLogin)?.value }
    }

    public func saveViewerLogin(_ login: String) async throws {
        try await database.write { db in try Setting(key: Setting.viewerLogin, value: login).upsert(db) }
    }

    private static func snapshot(_ db: Database) throws -> PullRequestSnapshot {
        var lists: [PullRequestList: [PullRequestSummary]] = [:]
        var refreshed: [PullRequestList: Date] = [:]
        for list in PullRequestList.allCases {
            lists[list] = try summaries(of: PullRequestRow.fetchAll(db, sql: """
                SELECT pullRequest.* FROM pullRequest
                JOIN listMembership ON listMembership.pullRequestId = pullRequest.id
                WHERE listMembership.list = ?
                ORDER BY pullRequest.updatedAt DESC
                """, arguments: [list.rawValue]), db)
            refreshed[list] = try ListRefresh.fetchOne(db, key: list.rawValue)?.refreshedAt
        }
        let unlisted = try summaries(of: PullRequestRow.fetchAll(db, sql: """
            SELECT * FROM pullRequest
            WHERE id NOT IN (SELECT pullRequestId FROM listMembership)
            ORDER BY updatedAt DESC
            """), db)
        return PullRequestSnapshot(lists: lists, unlisted: unlisted, refreshedAt: refreshed)
    }

    /// The PRs stored in `rows`, with their checks.
    static func summaries(of rows: [PullRequestRow], _ db: Database) throws -> [PullRequestSummary] {
        let checks = try Dictionary(
            grouping: PullRequestCheckRow.filter(rows.map(\.id).contains(Column("pullRequestId"))).order(Column("position")).fetchAll(db),
            by: \.pullRequestId
        )
        return rows.map { $0.summary(checkContexts: checks[$0.id, default: []].map(\.check)) }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("Pull request lists") { db in
            try db.create(table: "pullRequest") { t in
                t.primaryKey("id", .text)
                t.column("repository", .text).notNull()
                t.column("number", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("url", .text).notNull()
                t.column("author", .text)
                t.column("isDraft", .boolean).notNull()
                t.column("reviewDecision", .text)
                t.column("checkState", .text)
                t.column("updatedAt", .datetime).notNull()
                t.column("headRefName", .text).notNull()
                t.column("baseRefName", .text).notNull()
                t.uniqueKey(["repository", "number"])
            }
            // Which of the start screen's searches each PR came back from, and when it last did.
            try db.create(table: "listMembership") { t in
                t.column("list", .text).notNull()
                t.column("pullRequestId", .text).notNull().indexed().references("pullRequest", onDelete: .cascade)
                t.column("confirmedAt", .datetime).notNull()
                t.primaryKey(["list", "pullRequestId"])
            }
            try db.create(table: "listRefresh") { t in
                t.primaryKey("list", .text)
                t.column("refreshedAt", .datetime).notNull()
            }
        }
        // Where each repo is checked out locally. Independent of `pullRequest`, so a known
        // checkout outlives the PRs that led to finding it.
        migrator.registerMigration("Local repo checkouts") { db in
            try db.create(table: "localRepo") { t in
                t.primaryKey("nameWithOwner", .text)
                t.column("path", .text).notNull()
                t.column("verifiedAt", .datetime).notNull()
            }
        }
        // Earlier rows all came from `is:open` searches.
        migrator.registerMigration("Pull request state") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "state", .text).notNull().defaults(to: PullRequestState.open.rawValue)
                t.add(column: "mergedAt", .datetime)
                t.add(column: "closedAt", .datetime)
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        // Nullable, as earlier rows lack them until their list's next full load.
        migrator.registerMigration("Pull request commits") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "headRefOid", .text)
                t.add(column: "baseRefOid", .text)
            }
        }
        // Which PRs are open in tabs, in order, and when each PR's diff was last produced.
        migrator.registerMigration("Open tabs and diffs") { db in
            try db.create(table: "openTab") { t in
                t.primaryKey("position", .integer)
                t.column("pullRequestId", .text).notNull().unique().references("pullRequest", onDelete: .cascade)
            }
            try db.create(table: "pullRequestDiff") { t in
                t.primaryKey("pullRequestId", .text).references("pullRequest", onDelete: .cascade)
                t.column("headRefOid", .text).notNull()
                t.column("mergeBase", .text).notNull()
                t.column("producedAt", .datetime).notNull()
            }
        }
        // Nullable, as only looking a PR up by id fetches them.
        migrator.registerMigration("Pull request activity counts") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "commitCount", .integer)
                t.add(column: "commentCount", .integer)
                t.add(column: "reviewThreadCount", .integer)
            }
        }
        // The viewer's viewed state of each file in a PR, as GitHub last said or as last set here.
        migrator.registerMigration("Viewed files") { db in
            try db.create(table: "viewedFile") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequest", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("state", .text).notNull()
                t.primaryKey(["pullRequestId", "path"])
            }
        }
        // Each PR's conversation as GitHub last returned it, so a tab shows it before asking.
        migrator.registerMigration("Conversations") { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("pullRequestId", .text).references("pullRequest", onDelete: .cascade)
                t.column("authorLogin", .text)
                t.column("authorAvatarUrl", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("bodyHTML", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
            // One row per kind of event; the columns a kind doesn't use are null.
            try db.create(table: "timelineItem") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequest", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("actorLogin", .text)
                t.column("actorAvatarUrl", .text)
                t.column("bodyHTML", .text)
                t.column("isMinimized", .boolean)
                t.column("reviewState", .text)
                t.column("commitOid", .text)
                t.column("previousOid", .text)
                t.column("detail", .text)
                t.primaryKey(["pullRequestId", "id"])
            }
            try db.create(table: "reviewComment") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequest", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("reviewId", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("bodyHTML", .text).notNull()
                t.column("path", .text).notNull()
                t.column("line", .integer)
                t.column("originalLine", .integer)
                t.column("diffHunk", .text).notNull()
                t.column("isOutdated", .boolean).notNull()
                t.column("isMinimized", .boolean).notNull()
                t.column("replyToId", .text)
                t.primaryKey(["pullRequestId", "id"])
            }
            try db.create(table: "reviewThread") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequest", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("isResolved", .boolean).notNull()
                t.column("isOutdated", .boolean).notNull()
                t.column("path", .text).notNull()
                t.column("line", .integer)
                t.primaryKey(["pullRequestId", "id"])
            }
            try db.create(table: "threadComment") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequest", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("threadId", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("authorLogin", .text)
                t.column("authorAvatarUrl", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("bodyHTML", .text).notNull()
                t.column("isMinimized", .boolean).notNull()
                t.primaryKey(["pullRequestId", "id"])
            }
            try db.create(table: "checkContext") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequest", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("status", .text).notNull()
                t.column("description", .text)
                t.column("url", .text)
                t.primaryKey(["pullRequestId", "position"])
            }
        }
        // Each PR's head commit's checks one by one, as the lists' last lookup found them.
        migrator.registerMigration("Pull request checks") { db in
            try db.create(table: "pullRequestCheck") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequest", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("status", .text).notNull()
                t.column("description", .text)
                t.column("url", .text)
                t.primaryKey(["pullRequestId", "position"])
            }
        }
        // Nullable, as only looking a PR up by id fetches it.
        migrator.registerMigration("Pull request mergeable") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "mergeable", .text)
            }
        }
        // Who a PR's review is asked of, and each reviewer's latest review, from its conversation.
        migrator.registerMigration("Conversation reviewers") { db in
            try db.create(table: "conversationReviewer") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequest", onDelete: .cascade)
                // "request" or "review".
                t.column("role", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("nodeId", .text)
                t.column("login", .text).notNull()
                t.column("name", .text)
                t.column("avatarUrl", .text)
                t.column("reviewState", .text)
                t.column("submittedAt", .datetime)
                t.primaryKey(["pullRequestId", "role", "position"])
            }
        }
        // The description's markdown, which editing it starts from. Empty in a conversation
        // stored before, until it's next fetched.
        migrator.registerMigration("Conversation body") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "body", .text).notNull().defaults(to: "")
            }
        }
        // The files to review in each PR's last produced diff, replaced with its record.
        migrator.registerMigration("Diff reviewable files") { db in
            try db.create(table: "pullRequestDiffFile") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequestDiff", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.primaryKey(["pullRequestId", "path"])
            }
        }
        // Where each review thread is in the diff and what the viewer may do with it, and each
        // thread comment's REST id. A conversation stored before has them empty until it's
        // next fetched, so its threads stay where they were placed and offer no actions.
        migrator.registerMigration("Review thread anchoring") { db in
            try db.alter(table: "reviewThread") { t in
                t.add(column: "startLine", .integer)
                t.add(column: "side", .text).notNull().defaults(to: "RIGHT")
                t.add(column: "originalLine", .integer)
                t.add(column: "originalStartLine", .integer)
                t.add(column: "isOnFile", .boolean).notNull().defaults(to: false)
                t.add(column: "diffHunk", .text).notNull().defaults(to: "")
                t.add(column: "resolvedBy", .text)
                t.add(column: "viewerCanReply", .boolean).notNull().defaults(to: false)
                t.add(column: "viewerCanResolve", .boolean).notNull().defaults(to: false)
                t.add(column: "viewerCanUnresolve", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "threadComment") { t in
                t.add(column: "databaseId", .integer)
                t.add(column: "minimizedReason", .text)
            }
        }
        // Nullable, as only looking a PR up by id fetches it.
        migrator.registerMigration("Pull request merge state") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "mergeStateStatus", .text)
            }
        }
        // Every review asked for from here, to put those asked lately first. Independent of
        // `pullRequest`, so the history outlives the PRs.
        migrator.registerMigration("Review requests") { db in
            try db.create(table: "reviewRequest") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("repository", .text).notNull()
                t.column("reviewerId", .text)
                t.column("login", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("pullRequestId", .text).notNull()
                t.column("requestedAt", .datetime).notNull()
            }
            try db.create(index: "reviewRequestByRepository", on: "reviewRequest", columns: ["repository", "requestedAt"])
        }
        // Nullable, as only the to-review list's check of its requests fetches it.
        migrator.registerMigration("Pull request review requested at") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "reviewRequestedAt", .datetime)
            }
        }
        // The viewer's pending review and which thread comments are in it. A conversation
        // stored before has none until it's next fetched.
        migrator.registerMigration("Pending reviews") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "pendingReviewId", .text)
                t.add(column: "pendingReviewBody", .text)
                t.add(column: "pendingReviewCommentCount", .integer)
            }
            try db.alter(table: "threadComment") { t in
                t.add(column: "isPending", .boolean).notNull().defaults(to: false)
            }
        }
        // JSON; null until the PR is looked up by id, as searches don't fetch it.
        migrator.registerMigration("Pull request requested reviewers") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "requestedReviewers", .text)
            }
        }
        // The reactions anyone has made to the description, comments, reviews and thread
        // comments of a stored conversation, by what they're on. A conversation stored before
        // has none until it's next fetched.
        migrator.registerMigration("Conversation reactions") { db in
            try db.create(table: "reaction") { t in
                t.column("pullRequestId", .text).notNull().references("pullRequest", onDelete: .cascade)
                t.column("subjectId", .text).notNull()
                t.column("content", .text).notNull()
                t.column("count", .integer).notNull()
                t.column("viewerHasReacted", .boolean).notNull()
                t.primaryKey(["pullRequestId", "subjectId", "content"])
            }
        }
        // The viewer's comments and reviews shown before GitHub has answered for them.
        migrator.registerMigration("Comments being sent") { db in
            try db.alter(table: "threadComment") { t in
                t.add(column: "isSending", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "timelineItem") { t in
                t.add(column: "isSending", .boolean).notNull().defaults(to: false)
            }
        }
        // Null until the to-review list's check looks the PR up by id, as searches don't fetch it.
        // To review's refresh time is forgotten so its next refresh is a full load, which finds
        // the PRs the viewer reviewed before their reviews were searched for.
        migrator.registerMigration("Pull request viewer review") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "viewerReview", .text)
            }
            try db.execute(sql: "DELETE FROM listRefresh WHERE list = ?", arguments: [PullRequestList.toReview.rawValue])
        }
        // Which comments and reviews the viewer may edit or delete, and their edits shown
        // before GitHub has answered for them. A conversation stored before offers neither until
        // it's next fetched.
        migrator.registerMigration("Comment edits") { db in
            for table in ["threadComment", "timelineItem"] {
                try db.alter(table: table) { t in
                    t.add(column: "viewerCanUpdate", .boolean).notNull().defaults(to: false)
                    t.add(column: "viewerCanDelete", .boolean).notNull().defaults(to: false)
                    t.add(column: "isSaving", .boolean).notNull().defaults(to: false)
                }
            }
        }
        // The viewer's latest submitted review, by the commit it was made against, null in a
        // conversation stored before until it's next fetched; and the head of each PR's diff last
        // shown, apart from `pullRequestDiff` so it outlasts the PR's row once its tab closes and
        // it leaves the lists.
        migrator.registerMigration("Changes since") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "viewerReviewCommitOid", .text)
                t.add(column: "viewerReviewedAt", .datetime)
            }
            try db.create(table: "seenHead") { t in
                t.primaryKey("pullRequestId", .text)
                t.column("headRefOid", .text).notNull()
                t.column("seenAt", .datetime).notNull()
            }
        }
        // The viewer's verdict with when and on which head, so the header and To review can say
        // whether the PR has changed since: null until the conversation is next fetched, or the
        // to-review check next runs.
        migrator.registerMigration("Viewer verdicts") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "viewerReviewState", .text)
            }
            try db.alter(table: "pullRequest") { t in
                t.add(column: "viewerReviewedAt", .datetime)
                t.add(column: "viewerReviewCommitOid", .text)
            }
        }
        // Null on rows stored before until they're next fetched, so both lists' refresh times are
        // forgotten: their next refreshes are full loads, which fetch every listed PR.
        migrator.registerMigration("Pull request stacks") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "stackId", .text)
                t.add(column: "stackPosition", .integer)
                t.add(column: "stackParentId", .text)
            }
            try db.execute(sql: "DELETE FROM listRefresh")
        }
        // The viewer's latest review of any kind and what's happened since, so To review can say
        // they've reviewed a PR and whether it's been updated since: null until the to-review
        // check next runs.
        migrator.registerMigration("Viewer latest reviews") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "viewerLatestReviewState", .text)
                t.add(column: "viewerLatestReviewedAt", .datetime)
                t.add(column: "viewerLatestReviewCommitOid", .text)
                t.add(column: "commitsSinceViewerReview", .integer)
                t.add(column: "lastCommittedAt", .datetime)
                t.add(column: "forcePushedSinceViewerReviewAt", .datetime)
            }
        }
        // When the viewer was first asked to review, and the head the newest request for changes
        // was made on, for the TODO view's order and sections: null until the next check.
        migrator.registerMigration("TODO signals") { db in
            try db.alter(table: "pullRequest") { t in
                t.add(column: "firstReviewRequestedAt", .datetime)
                t.add(column: "changesRequestedCommitOid", .text)
            }
        }
        // Comments' and reviews' REST ids, which github.com's links to them name: null in a
        // conversation stored before until it's next fetched.
        migrator.registerMigration("Timeline database ids") { db in
            try db.alter(table: "timelineItem") { t in
                t.add(column: "databaseId", .integer)
            }
        }
        return migrator
    }

    private static func upsert(_ pullRequests: [PullRequestSummary], into list: PullRequestList, at refreshedAt: Date, _ db: Database) throws {
        for pullRequest in pullRequests {
            try upsert(pullRequest, db)
            try ListMembership(list: list.rawValue, pullRequestId: pullRequest.id, confirmedAt: refreshedAt).upsert(db)
        }
    }

    /// Stores the PR's row, whichever list it's in, if any.
    static func upsert(_ pullRequest: PullRequestSummary, _ db: Database) throws {
        // A row left from a repo that was deleted and recreated would hold the same
        // repo and number under an old id.
        try PullRequestRow
            .filter(Column("repository") == pullRequest.repository && Column("number") == pullRequest.number && Column("id") != pullRequest.id)
            .deleteAll(db)
        // Searches don't fetch what's only looked up by id, so the last of that is kept.
        let stored = try PullRequestRow.fetchOne(db, key: pullRequest.id)
        try PullRequestRow(pullRequest, keepingLookupsFrom: stored).upsert(db)
    }

    /// PRs in neither list are no longer needed, unless open in a tab or stacked, through open
    /// PRs, with one that's listed or open in a tab.
    static func deleteUnlisted(_ db: Database) throws {
        try db.execute(sql: """
            WITH RECURSIVE kept(id) AS (
                SELECT pullRequestId FROM listMembership
                UNION SELECT pullRequestId FROM openTab
                UNION SELECT other.id FROM kept
                    JOIN pullRequest AS this ON this.id = kept.id AND this.state = 'OPEN'
                    JOIN pullRequest AS other ON other.repository = this.repository AND other.state = 'OPEN' AND (
                        other.stackId = this.stackId OR other.id = this.stackParentId OR other.stackParentId = this.id
                        OR other.headRefName = this.baseRefName OR other.baseRefName = this.headRefName
                    )
            )
            DELETE FROM pullRequest WHERE id NOT IN kept
            """)
    }
}

/// The stored lists and when each was last refreshed from GitHub.
public struct PullRequestSnapshot: Sendable, Equatable {
    private let lists: [PullRequestList: [PullRequestSummary]]
    /// The stored PRs in neither list: those open in tabs, and those stacked with listed ones.
    /// Newest first.
    public let unlisted: [PullRequestSummary]
    private let refreshedAt: [PullRequestList: Date]

    /// Nothing stored and nothing refreshed.
    public static let empty = PullRequestSnapshot(lists: [:], unlisted: [], refreshedAt: [:])

    init(lists: [PullRequestList: [PullRequestSummary]], unlisted: [PullRequestSummary], refreshedAt: [PullRequestList: Date]) {
        self.lists = lists
        self.unlisted = unlisted
        self.refreshedAt = refreshedAt
    }

    /// Newest first.
    public subscript(list: PullRequestList) -> [PullRequestSummary] {
        lists[list, default: []]
    }

    /// Nil if the list has never been refreshed.
    public func refreshedAt(_ list: PullRequestList) -> Date? {
        refreshedAt[list]
    }
}

struct PullRequestRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pullRequest"

    let id: String
    let repository: String
    let number: Int
    let title: String
    let url: URL
    let author: String?
    let isDraft: Bool
    let state: String
    let mergedAt: Date?
    let closedAt: Date?
    let reviewDecision: String?
    let checkState: String?
    let updatedAt: Date
    let headRefName: String
    let baseRefName: String
    let headRefOid: String?
    let baseRefOid: String?
    let commitCount: Int?
    let commentCount: Int?
    let reviewThreadCount: Int?
    let mergeable: String?
    let mergeStateStatus: String?
    let reviewRequestedAt: Date?
    let firstReviewRequestedAt: Date?
    let changesRequestedCommitOid: String?
    let requestedReviewers: [StoredReviewer]?
    let viewerReview: String?
    let viewerReviewedAt: Date?
    let viewerReviewCommitOid: String?
    let stackId: String?
    let stackPosition: Int?
    let stackParentId: String?
    let viewerLatestReviewState: String?
    let viewerLatestReviewedAt: Date?
    let viewerLatestReviewCommitOid: String?
    let commitsSinceViewerReview: Int?
    let lastCommittedAt: Date?
    let forcePushedSinceViewerReviewAt: Date?

    /// Anything `pullRequest` lacks because only a lookup by id fetches it is kept from `stored`.
    init(_ pullRequest: PullRequestSummary, keepingLookupsFrom stored: PullRequestRow?) {
        id = pullRequest.id
        repository = pullRequest.repository
        number = pullRequest.number
        title = pullRequest.title
        url = pullRequest.url
        author = pullRequest.author
        isDraft = pullRequest.isDraft
        state = pullRequest.state.rawValue
        mergedAt = pullRequest.mergedAt
        closedAt = pullRequest.closedAt
        reviewDecision = pullRequest.reviewDecision?.rawValue
        checkState = pullRequest.checks?.rawValue
        updatedAt = pullRequest.updatedAt
        headRefName = pullRequest.headRefName
        baseRefName = pullRequest.baseRefName
        headRefOid = pullRequest.headRefOid
        baseRefOid = pullRequest.baseRefOid
        commitCount = pullRequest.commitCount ?? stored?.commitCount
        commentCount = pullRequest.commentCount ?? stored?.commentCount
        reviewThreadCount = pullRequest.reviewThreadCount ?? stored?.reviewThreadCount
        mergeable = pullRequest.mergeable?.rawValue ?? stored?.mergeable
        mergeStateStatus = pullRequest.mergeStateStatus?.rawValue ?? stored?.mergeStateStatus
        reviewRequestedAt = pullRequest.reviewRequestedAt ?? stored?.reviewRequestedAt
        firstReviewRequestedAt = pullRequest.firstReviewRequestedAt ?? stored?.firstReviewRequestedAt
        changesRequestedCommitOid = pullRequest.changesRequestedCommitOid ?? stored?.changesRequestedCommitOid
        requestedReviewers = pullRequest.requestedReviewers.map { $0.map(StoredReviewer.init) } ?? stored?.requestedReviewers
        viewerReview = pullRequest.viewerReview?.rawValue ?? stored?.viewerReview
        // When and on which head go with the verdict they describe.
        viewerReviewedAt = pullRequest.viewerReview == nil ? stored?.viewerReviewedAt : pullRequest.viewerReviewedAt
        viewerReviewCommitOid = pullRequest.viewerReview == nil ? stored?.viewerReviewCommitOid : pullRequest.viewerReviewCommitOid
        stackId = pullRequest.stackId
        stackPosition = pullRequest.stackPosition
        stackParentId = pullRequest.stackParentId
        let latest = pullRequest.viewerLatestReview
        viewerLatestReviewState = latest?.state.rawValue ?? stored?.viewerLatestReviewState
        viewerLatestReviewedAt = latest == nil ? stored?.viewerLatestReviewedAt : latest?.submittedAt
        viewerLatestReviewCommitOid = latest == nil ? stored?.viewerLatestReviewCommitOid : latest?.commitOid
        commitsSinceViewerReview = latest == nil ? stored?.commitsSinceViewerReview : latest?.commitsSince
        lastCommittedAt = latest == nil ? stored?.lastCommittedAt : latest?.lastCommittedAt
        forcePushedSinceViewerReviewAt = latest == nil ? stored?.forcePushedSinceViewerReviewAt : latest?.forcePushedAt
    }

    func summary(checkContexts: [CheckContext]) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repository: repository,
            number: number,
            title: title,
            url: url,
            author: author,
            isDraft: isDraft,
            state: PullRequestState(lenientRawValue: state),
            mergedAt: mergedAt,
            closedAt: closedAt,
            reviewDecision: reviewDecision.map(ReviewDecision.init(lenientRawValue:)),
            // GitHub's rollup is stored as given; the tolerated Codecov failures are let off here.
            checks: checkState.map { CheckState(lenientRawValue: $0).tolerating(checkContexts) },
            checkContexts: checkContexts,
            mergeable: mergeable.map(MergeableState.init(lenientRawValue:)),
            mergeStateStatus: mergeStateStatus.map(MergeStateStatus.init(lenientRawValue:)),
            updatedAt: updatedAt,
            headRefName: headRefName,
            baseRefName: baseRefName,
            headRefOid: headRefOid,
            baseRefOid: baseRefOid,
            commitCount: commitCount,
            commentCount: commentCount,
            reviewThreadCount: reviewThreadCount,
            reviewRequestedAt: reviewRequestedAt,
            firstReviewRequestedAt: firstReviewRequestedAt,
            changesRequestedCommitOid: changesRequestedCommitOid,
            requestedReviewers: requestedReviewers?.map(\.reviewer),
            viewerReview: viewerReview.map(ReviewState.init(lenientRawValue:)),
            viewerReviewedAt: viewerReviewedAt,
            viewerReviewCommitOid: viewerReviewCommitOid,
            stackId: stackId,
            stackPosition: stackPosition,
            stackParentId: stackParentId,
            viewerLatestReview: viewerLatestReviewState.map { state in
                ViewerLatestReview(
                    state: ReviewState(lenientRawValue: state),
                    submittedAt: viewerLatestReviewedAt,
                    commitOid: viewerLatestReviewCommitOid,
                    commitsSince: commitsSinceViewerReview,
                    lastCommittedAt: lastCommittedAt,
                    forcePushedAt: forcePushedSinceViewerReviewAt
                )
            }
        )
    }
}

private struct PullRequestCheckRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pullRequestCheck"

    let pullRequestId: String
    let position: Int
    let name: String
    let status: String
    let description: String?
    let url: String?

    init(pullRequestId: String, position: Int, _ check: CheckContext) {
        self.pullRequestId = pullRequestId
        self.position = position
        name = check.name
        status = check.status.rawValue
        description = check.description
        url = check.url
    }

    var check: CheckContext {
        CheckContext(name: name, status: CheckStatus(rawValue: status) ?? .neutral, description: description, url: url)
    }
}

/// A requested reviewer as kept in the `requestedReviewers` column's JSON.
struct StoredReviewer: Codable {
    /// "user", "team" or "other".
    let kind: String
    let name: String?

    init(_ reviewer: RequestedReviewer) {
        switch reviewer {
        case let .user(login): (kind, name) = ("user", login)
        case let .team(slug): (kind, name) = ("team", slug)
        case .other: (kind, name) = ("other", nil)
        }
    }

    var reviewer: RequestedReviewer {
        switch (kind, name) {
        case let ("user", login?): .user(login: login)
        case let ("team", slug?): .team(slug: slug)
        default: .other
        }
    }
}

private struct ListMembership: Codable, PersistableRecord {
    static let databaseTableName = "listMembership"

    let list: String
    let pullRequestId: String
    let confirmedAt: Date
}

private struct ListRefresh: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "listRefresh"

    let list: String
    let refreshedAt: Date
}

struct Setting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setting"
    static let viewerLogin = "viewerLogin"

    let key: String
    let value: String
}
