import Foundation
import GRDB

/// A GitHub repo's local checkout, as last confirmed on disk.
public struct LocalRepo: Sendable, Equatable {
    /// `owner/name`.
    public let nameWithOwner: String
    public let path: URL
    public let verifiedAt: Date

    public init(nameWithOwner: String, path: URL, verifiedAt: Date) {
        self.nameWithOwner = nameWithOwner
        self.path = path
        self.verifiedAt = verifiedAt
    }
}

extension PullRequestStore {
    /// The stored checkouts of whichever of `repositories` have one, keyed by `owner/name`.
    public func localRepos(for repositories: [String]) throws -> [String: LocalRepo] {
        try database.read { db in
            try LocalRepoRow
                .filter(repositories.contains(Column("nameWithOwner")))
                .fetchAll(db)
                .reduce(into: [:]) { $0[$1.nameWithOwner] = $1.localRepo }
        }
    }

    /// Records or re-confirms `saving`, and forgets the checkouts of `removing`, in one write.
    public func updateLocalRepos(saving: [LocalRepo], removing: [String] = []) async throws {
        try await database.write { db in
            _ = try LocalRepoRow.deleteAll(db, keys: removing)
            for repo in saving {
                try LocalRepoRow(repo).upsert(db)
            }
        }
    }
}

private struct LocalRepoRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "localRepo"

    let nameWithOwner: String
    let path: String
    let verifiedAt: Date

    init(_ repo: LocalRepo) {
        nameWithOwner = repo.nameWithOwner
        path = repo.path.path(percentEncoded: false)
        verifiedAt = repo.verifiedAt
    }

    var localRepo: LocalRepo {
        LocalRepo(nameWithOwner: nameWithOwner, path: URL(filePath: path, directoryHint: .isDirectory), verifiedAt: verifiedAt)
    }
}
