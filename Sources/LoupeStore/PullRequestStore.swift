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
            for pullRequest in pullRequests {
                // A row left from a repo that was deleted and recreated would hold the same
                // repo and number under an old id.
                try PullRequestRow
                    .filter(Column("repository") == pullRequest.repository && Column("number") == pullRequest.number && Column("id") != pullRequest.id)
                    .deleteAll(db)
                try PullRequestRow(pullRequest).upsert(db)
                try ListMembership(list: list.rawValue, pullRequestId: pullRequest.id, confirmedAt: refreshedAt).upsert(db)
            }
            try ListMembership
                .filter(Column("list") == list.rawValue && !pullRequests.map(\.id).contains(Column("pullRequestId")))
                .deleteAll(db)
            // PRs in neither list are no longer needed.
            try db.execute(sql: "DELETE FROM pullRequest WHERE id NOT IN (SELECT pullRequestId FROM listMembership)")
            try ListRefresh(list: list.rawValue, refreshedAt: refreshedAt).upsert(db)
            return try Self.snapshot(db)
        }
    }

    private static func snapshot(_ db: Database) throws -> PullRequestSnapshot {
        var lists: [PullRequestList: [PullRequestSummary]] = [:]
        var refreshed: [PullRequestList: Date] = [:]
        for list in PullRequestList.allCases {
            lists[list] = try PullRequestRow.fetchAll(db, sql: """
                SELECT pullRequest.* FROM pullRequest
                JOIN listMembership ON listMembership.pullRequestId = pullRequest.id
                WHERE listMembership.list = ?
                ORDER BY pullRequest.updatedAt DESC
                """, arguments: [list.rawValue]).map(\.summary)
            refreshed[list] = try ListRefresh.fetchOne(db, key: list.rawValue)?.refreshedAt
        }
        return PullRequestSnapshot(lists: lists, refreshedAt: refreshed)
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
        return migrator
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

private struct PullRequestRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pullRequest"

    let id: String
    let repository: String
    let number: Int
    let title: String
    let url: URL
    let author: String?
    let isDraft: Bool
    let reviewDecision: String?
    let checkState: String?
    let updatedAt: Date
    let headRefName: String
    let baseRefName: String

    init(_ pullRequest: PullRequestSummary) {
        id = pullRequest.id
        repository = pullRequest.repository
        number = pullRequest.number
        title = pullRequest.title
        url = pullRequest.url
        author = pullRequest.author
        isDraft = pullRequest.isDraft
        reviewDecision = pullRequest.reviewDecision?.rawValue
        checkState = pullRequest.checks?.rawValue
        updatedAt = pullRequest.updatedAt
        headRefName = pullRequest.headRefName
        baseRefName = pullRequest.baseRefName
    }

    var summary: PullRequestSummary {
        PullRequestSummary(
            id: id,
            repository: repository,
            number: number,
            title: title,
            url: url,
            author: author,
            isDraft: isDraft,
            reviewDecision: reviewDecision.map(ReviewDecision.init(lenientRawValue:)),
            checks: checkState.map(CheckState.init(lenientRawValue:)),
            updatedAt: updatedAt,
            headRefName: headRefName,
            baseRefName: baseRefName
        )
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
