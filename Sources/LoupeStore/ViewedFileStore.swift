import Foundation
import GRDB
import LoupeModel

extension PullRequestStore {
    /// The stored viewed state of each file in the PR, keyed by path; files never stored are
    /// left out.
    public func viewedStates(of pullRequestId: String) throws -> [String: FileViewedState] {
        try database.read { db in
            try ViewedFileRow
                .filter(Column("pullRequestId") == pullRequestId)
                .fetchAll(db)
                .reduce(into: [:]) { $0[$1.path] = FileViewedState(lenientRawValue: $1.state) }
        }
    }

    /// Makes the PR's stored states exactly `states`, as GitHub returned them.
    public func replaceViewedStates(of pullRequestId: String, with states: [String: FileViewedState]) async throws {
        try await database.write { db in
            try ViewedFileRow.filter(Column("pullRequestId") == pullRequestId).deleteAll(db)
            for (path, state) in states {
                try ViewedFileRow(pullRequestId: pullRequestId, path: path, state: state.rawValue).insert(db)
            }
        }
    }

    public func saveViewedState(_ state: FileViewedState, of path: String, in pullRequestId: String) async throws {
        try await database.write { db in
            try ViewedFileRow(pullRequestId: pullRequestId, path: path, state: state.rawValue).upsert(db)
        }
    }
}

private struct ViewedFileRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "viewedFile"

    let pullRequestId: String
    let path: String
    let state: String
}
