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

    /// Updates the stored rows of `pullRequests`, as looked up directly rather than through a
    /// list, leaving which lists they're in alone. PRs no longer stored are left out, as nothing
    /// shows them.
    @discardableResult
    public func update(_ pullRequests: [PullRequestSummary]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for pullRequest in pullRequests where try PullRequestRow.exists(db, key: pullRequest.id) {
                try PullRequestRow(pullRequest).update(db)
            }
            return try Self.snapshot(db)
        }
    }

    /// Replaces the stored checks of each PR in `checks`, keyed by id, with the overall state and
    /// each check as last looked up. PRs no longer stored are left out, as nothing shows them.
    @discardableResult
    public func updateChecks(_ checks: [String: PullRequestChecks]) async throws -> PullRequestSnapshot {
        try await database.write { db in
            for (id, checks) in checks where try PullRequestRow.exists(db, key: id) {
                try db.execute(sql: "UPDATE pullRequest SET checkState = ? WHERE id = ?", arguments: [checks.state?.rawValue, id])
                try PullRequestCheckRow.filter(Column("pullRequestId") == id).deleteAll(db)
                for (position, check) in checks.contexts.enumerated() {
                    try PullRequestCheckRow(pullRequestId: id, position: position, check).insert(db)
                }
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
        return PullRequestSnapshot(lists: lists, refreshedAt: refreshed)
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
        return migrator
    }

    private static func upsert(_ pullRequests: [PullRequestSummary], into list: PullRequestList, at refreshedAt: Date, _ db: Database) throws {
        for pullRequest in pullRequests {
            // A row left from a repo that was deleted and recreated would hold the same
            // repo and number under an old id.
            try PullRequestRow
                .filter(Column("repository") == pullRequest.repository && Column("number") == pullRequest.number && Column("id") != pullRequest.id)
                .deleteAll(db)
            // Searches don't fetch the counts, so the last ones looked up are kept.
            let stored = try PullRequestRow.fetchOne(db, key: pullRequest.id)
            try PullRequestRow(pullRequest, keepingCountsFrom: stored).upsert(db)
            try ListMembership(list: list.rawValue, pullRequestId: pullRequest.id, confirmedAt: refreshedAt).upsert(db)
        }
    }

    /// PRs in neither list are no longer needed, unless open in a tab.
    static func deleteUnlisted(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM pullRequest
            WHERE id NOT IN (SELECT pullRequestId FROM listMembership)
            AND id NOT IN (SELECT pullRequestId FROM openTab)
            """)
    }
}

/// The stored lists and when each was last refreshed from GitHub.
public struct PullRequestSnapshot: Sendable, Equatable {
    private let lists: [PullRequestList: [PullRequestSummary]]
    private let refreshedAt: [PullRequestList: Date]

    /// Nothing stored and nothing refreshed.
    public static let empty = PullRequestSnapshot(lists: [:], refreshedAt: [:])

    init(lists: [PullRequestList: [PullRequestSummary]], refreshedAt: [PullRequestList: Date]) {
        self.lists = lists
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

    init(_ pullRequest: PullRequestSummary, keepingCountsFrom stored: PullRequestRow? = nil) {
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
            checks: checkState.map(CheckState.init(lenientRawValue:)),
            checkContexts: checkContexts,
            updatedAt: updatedAt,
            headRefName: headRefName,
            baseRefName: baseRefName,
            headRefOid: headRefOid,
            baseRefOid: baseRefOid,
            commitCount: commitCount,
            commentCount: commentCount,
            reviewThreadCount: reviewThreadCount
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
