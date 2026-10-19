import Foundation
import GRDB
import LoupeModel

/// The PRs open in windows, in order, and which was frontmost.
public struct SavedTabs: Sendable, Equatable {
    public let pullRequests: [PullRequestSummary]
    /// Nil when the PR lists were frontmost.
    public let selected: String?
}

/// When a PR's diff was last produced, of which head commit, and which of its files are to
/// review rather than hidden as vendored, lockfiles or generated.
public struct DiffRecord: Sendable, Equatable {
    public let pullRequestId: String
    public let headRefOid: String
    public let mergeBase: String
    public let producedAt: Date
    public let reviewablePaths: [String]

    public init(pullRequestId: String, headRefOid: String, mergeBase: String, producedAt: Date, reviewablePaths: [String]) {
        self.pullRequestId = pullRequestId
        self.headRefOid = headRefOid
        self.mergeBase = mergeBase
        self.producedAt = producedAt
        self.reviewablePaths = reviewablePaths
    }
}

/// The head of a PR's diff the viewer was shown, and when.
public struct SeenHead: Sendable, Equatable {
    public let headRefOid: String
    public let seenAt: Date

    public init(headRefOid: String, seenAt: Date) {
        self.headRefOid = headRefOid
        self.seenAt = seenAt
    }
}

extension PullRequestStore {
    public func openTabs() throws -> SavedTabs {
        try database.read { db in
            let pullRequests = try Self.summaries(of: PullRequestRow.fetchAll(db, sql: """
                SELECT pullRequest.* FROM openTab
                JOIN pullRequest ON pullRequest.id = openTab.pullRequestId
                ORDER BY openTab.position
                """), db)
            let selected = try Setting.fetchOne(db, key: Setting.selectedTab)?.value
            return SavedTabs(pullRequests: pullRequests, selected: pullRequests.contains { $0.id == selected } ? selected : nil)
        }
    }

    /// Replaces the open tabs with the PRs with `ids`, in order. A tab keeps its PR stored after
    /// the PR leaves both lists; closing it lets the PR go. Written synchronously, as it's small
    /// and successive saves must land in order.
    public func saveOpenTabs(_ ids: [String], selected: String?) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM openTab")
            for (position, id) in ids.enumerated() {
                try db.execute(sql: "INSERT INTO openTab (position, pullRequestId) VALUES (?, ?)", arguments: [position, id])
            }
            if let selected {
                try Setting(key: Setting.selectedTab, value: selected).upsert(db)
            } else {
                _ = try Setting.deleteOne(db, key: Setting.selectedTab)
            }
            try Self.deleteUnlisted(db)
        }
    }

    /// Stores a PR looked up on its own, such as one a link names, and adds its tab after the
    /// others unless it's open already. One write, so a list refresh can't drop it as unlisted
    /// before its tab is saved.
    public func addOpenTab(_ pullRequest: PullRequestSummary) async throws {
        try await database.write { db in
            try Self.upsert(pullRequest, db)
            let isOpen = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM openTab WHERE pullRequestId = ?)", arguments: [pullRequest.id]) ?? false
            guard !isOpen else { return }
            try db.execute(sql: "INSERT INTO openTab (position, pullRequestId) SELECT COALESCE(MAX(position) + 1, 0), ? FROM openTab", arguments: [pullRequest.id])
        }
    }

    /// Replaces the PR's record, reviewable paths and all.
    public func recordDiff(_ record: DiffRecord) async throws {
        try await database.write { db in
            try DiffRecordRow(record).upsert(db)
            try DiffFileRow.filter(Column("pullRequestId") == record.pullRequestId).deleteAll(db)
            for path in record.reviewablePaths {
                try DiffFileRow(pullRequestId: record.pullRequestId, path: path).insert(db)
            }
        }
    }

    public func diffRecord(for pullRequestId: String) throws -> DiffRecord? {
        try database.read { db in
            try DiffRecordRow.fetchOne(db, key: pullRequestId)?.record(reviewablePaths: Self.reviewablePaths(of: pullRequestId, db))
        }
    }

    /// Records `headRefOid` as the head of the PR's diff the viewer was last shown. Kept after
    /// the PR leaves the lists and its tab closes, for when it's next opened.
    public func recordSeenHead(_ headRefOid: String, of pullRequestId: String, at seenAt: Date) async throws {
        try await database.write { db in
            try SeenHeadRow(pullRequestId: pullRequestId, headRefOid: headRefOid, seenAt: seenAt).upsert(db)
        }
    }

    /// The head of the PR's diff the viewer was last shown, and when; nil if never.
    public func seenHead(of pullRequestId: String) throws -> SeenHead? {
        try database.read { db in
            try SeenHeadRow.fetchOne(db, key: pullRequestId).map { SeenHead(headRefOid: $0.headRefOid, seenAt: $0.seenAt) }
        }
    }

    /// How far the review of each PR whose diff has been produced has got, by PR id.
    public func reviewProgress() throws -> [String: ReviewProgress] {
        try database.read { db in
            try DiffRecordRow.fetchAll(db).reduce(into: [:]) { progress, row in
                progress[row.pullRequestId] = try Self.reviewProgress(of: row, db)
            }
        }
    }

    /// Nil until the PR's diff has been produced.
    public func reviewProgress(of pullRequestId: String) throws -> ReviewProgress? {
        try database.read { db in
            try DiffRecordRow.fetchOne(db, key: pullRequestId).map { try Self.reviewProgress(of: $0, db) }
        }
    }

    private static func reviewProgress(of row: DiffRecordRow, _ db: Database) throws -> ReviewProgress {
        ReviewProgress(
            diffedHeadRefOid: row.headRefOid,
            reviewablePaths: try reviewablePaths(of: row.pullRequestId, db),
            viewedStates: try viewedStates(of: row.pullRequestId, db)
        )
    }

    private static func reviewablePaths(of pullRequestId: String, _ db: Database) throws -> [String] {
        try DiffFileRow.filter(Column("pullRequestId") == pullRequestId).fetchAll(db).map(\.path)
    }
}

extension Setting {
    static let selectedTab = "selectedTab"
}

private struct DiffRecordRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pullRequestDiff"

    let pullRequestId: String
    let headRefOid: String
    let mergeBase: String
    let producedAt: Date

    init(_ record: DiffRecord) {
        pullRequestId = record.pullRequestId
        headRefOid = record.headRefOid
        mergeBase = record.mergeBase
        producedAt = record.producedAt
    }

    func record(reviewablePaths: [String]) -> DiffRecord {
        DiffRecord(pullRequestId: pullRequestId, headRefOid: headRefOid, mergeBase: mergeBase, producedAt: producedAt, reviewablePaths: reviewablePaths)
    }
}

private struct SeenHeadRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "seenHead"

    let pullRequestId: String
    let headRefOid: String
    let seenAt: Date
}

private struct DiffFileRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pullRequestDiffFile"

    let pullRequestId: String
    let path: String
}
