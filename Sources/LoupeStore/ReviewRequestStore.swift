import Foundation
import GRDB
import LoupeModel

extension PullRequestStore {
    /// Records that `reviewer` was asked to review the PR with `pullRequestId` in `repository`
    /// (`owner/name`) at `requestedAt`. Each request is kept, re-requests included.
    public func recordReviewRequest(of reviewer: Reviewer, in repository: String, on pullRequestId: String, at requestedAt: Date) async throws {
        try await database.write { db in
            try ReviewRequestRow(
                repository: repository.lowercased(),
                reviewerId: reviewer.nodeId,
                login: reviewer.login,
                kind: reviewer.kind.rawValue,
                pullRequestId: pullRequestId,
                requestedAt: requestedAt
            ).insert(db)
        }
    }

    /// When each reviewer was last asked to review in `repository`, keyed by `Reviewer.id`.
    /// Requests made here count at their time; anyone asked or reviewing on the viewer's own
    /// stored PRs counts at that PR's last update, as GitHub doesn't say when they were asked.
    public func lastReviewRequests(in repository: String) throws -> [String: Date] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT kind, login, MAX(usedAt) AS usedAt FROM (
                    SELECT kind, login, requestedAt AS usedAt FROM reviewRequest
                    WHERE repository = :repository
                    UNION ALL
                    SELECT conversationReviewer.kind, conversationReviewer.login, pullRequest.updatedAt
                    FROM conversationReviewer
                    JOIN pullRequest ON pullRequest.id = conversationReviewer.pullRequestId
                    WHERE lower(pullRequest.repository) = :repository
                    AND pullRequest.author = (SELECT value FROM setting WHERE key = :viewerLogin)
                )
                GROUP BY kind, login
                """, arguments: ["repository": repository.lowercased(), "viewerLogin": Setting.viewerLogin])
            .reduce(into: [:]) { uses, row in
                let kind: String = row["kind"]
                let login: String = row["login"]
                guard let kind = Reviewer.Kind(rawValue: kind) else { return }
                uses[Reviewer(kind: kind, nodeId: nil, login: login).id] = row["usedAt"]
            }
        }
    }
}

/// A review asked for from Loupe, kept so who's been asked lately can come first next time.
/// Not tied to `pullRequest`, so the history outlives the PRs it was made on.
private struct ReviewRequestRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reviewRequest"

    /// Lowercased `owner/name`.
    let repository: String
    /// GitHub's node id, nil if GitHub didn't give one.
    let reviewerId: String?
    /// A user's login or a team's `org/slug`.
    let login: String
    let kind: String
    let pullRequestId: String
    let requestedAt: Date
}
