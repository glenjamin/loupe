import Foundation
import GRDB
import LoupeModel

/// The PRs open in tabs, in order, and which tab was selected.
public struct SavedTabs: Sendable, Equatable {
    public let pullRequests: [PullRequestSummary]
    /// Nil when the PR lists' tab was selected.
    public let selected: String?
}

/// When a PR's diff was last produced, and of which head commit.
public struct DiffRecord: Sendable, Equatable {
    public let pullRequestId: String
    public let headRefOid: String
    public let mergeBase: String
    public let producedAt: Date

    public init(pullRequestId: String, headRefOid: String, mergeBase: String, producedAt: Date) {
        self.pullRequestId = pullRequestId
        self.headRefOid = headRefOid
        self.mergeBase = mergeBase
        self.producedAt = producedAt
    }
}

extension PullRequestStore {
    public func openTabs() throws -> SavedTabs {
        try database.read { db in
            let pullRequests = try PullRequestRow.fetchAll(db, sql: """
                SELECT pullRequest.* FROM openTab
                JOIN pullRequest ON pullRequest.id = openTab.pullRequestId
                ORDER BY openTab.position
                """).map(\.summary)
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

    public func recordDiff(_ record: DiffRecord) async throws {
        try await database.write { db in try DiffRecordRow(record).upsert(db) }
    }

    public func diffRecord(for pullRequestId: String) throws -> DiffRecord? {
        try database.read { db in try DiffRecordRow.fetchOne(db, key: pullRequestId)?.record }
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

    var record: DiffRecord {
        DiffRecord(pullRequestId: pullRequestId, headRefOid: headRefOid, mergeBase: mergeBase, producedAt: producedAt)
    }
}
