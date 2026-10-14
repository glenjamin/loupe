import Foundation
import LoupeStore

/// Finds where GitHub repos are checked out on this machine, remembering what it finds in the
/// store. Only ever reads from the checkouts.
public struct CheckoutResolver: Sendable {
    /// `~/Development/tamarinworks` then `~/Development/GitHub`.
    public static var defaultSearchRoots: [URL] {
        let development = URL.homeDirectory.appending(path: "Development", directoryHint: .isDirectory)
        return [
            development.appending(path: "tamarinworks", directoryHint: .isDirectory),
            development.appending(path: "GitHub", directoryHint: .isDirectory),
        ]
    }

    /// Directories searched, in order, for a checkout named after a repo that has none stored.
    public let searchRoots: [URL]
    private let store: PullRequestStore

    public init(store: PullRequestStore, searchRoots: [URL] = defaultSearchRoots) {
        self.store = store
        self.searchRoots = searchRoots
    }

    /// The checkout of each of `repositories` (`owner/name`) that can be found; the rest are left
    /// out. Stored checkouts whose directory has gone are forgotten and searched for afresh, and
    /// new finds are stored. Misses aren't, so they're searched for again next time.
    public func resolve(_ repositories: some Collection<String>) async throws -> [String: URL] {
        let repositories = Array(Set(repositories))
        var found: [String: URL] = [:]
        var gone: [String] = []
        for (repository, local) in try store.localRepos(for: repositories) {
            if isGitCheckout(local.path) {
                found[repository] = local.path
            } else {
                gone.append(repository)
            }
        }

        let unknown = repositories.filter { found[$0] == nil }
        try await withThrowingTaskGroup(of: (String, URL?).self) { group in
            for repository in unknown {
                group.addTask { (repository, try await search(for: repository)) }
            }
            for try await case let (repository, directory?) in group {
                found[repository] = directory
            }
        }

        let now = Date.now
        try await store.updateLocalRepos(
            saving: found.map { LocalRepo(nameWithOwner: $0.key, path: $0.value, verifiedAt: now) },
            removing: gone
        )
        return found
    }

    /// Stores `directory` as the checkout of `repository`, if it is one: a git repo with a remote
    /// pointing at that repo on GitHub.
    public func locate(_ repository: String, at directory: URL) async throws -> URL {
        let directory = directory.standardizedFileURL
        guard isGitCheckout(directory) else { throw CheckoutError.notAGitRepository(directory) }
        let remotes = await Git.remotes(of: directory)
        guard remotes.matching(repository) != nil else {
            throw CheckoutError.noMatchingRemote(directory, expected: repository, remotes: remotes.map(\.url))
        }
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: repository, path: directory, verifiedAt: .now)])
        return directory
    }

    /// The first directory named after the repo under a search root with a remote pointing at that
    /// repo, preferring one whose `origin` does over a fork's checkout that has it as another
    /// remote. Other copies, like worktrees named `<repo>-<branch>`, aren't considered.
    private func search(for repository: String) async throws -> URL? {
        guard let name = repository.split(separator: "/").last else { return nil }
        var fork: URL?
        for root in searchRoots {
            let candidate = root.appending(path: String(name), directoryHint: .isDirectory)
            guard isGitCheckout(candidate), let remote = await Git.remotes(of: candidate).matching(repository) else { continue }
            if remote.name == "origin" { return candidate }
            fork = fork ?? candidate
        }
        return fork
    }
}

public enum CheckoutError: Error, LocalizedError, Equatable {
    case notAGitRepository(URL)
    /// The directory's remotes' URLs, none of which is the expected repo.
    case noMatchingRemote(URL, expected: String, remotes: [String])

    public var errorDescription: String? {
        switch self {
        case let .notAGitRepository(directory):
            "\(directory.path(percentEncoded: false)) isn't a git repository."
        case let .noMatchingRemote(directory, expected, []):
            "\(directory.path(percentEncoded: false)) has no remotes, so it can't be confirmed as github.com/\(expected)."
        case let .noMatchingRemote(directory, expected, remotes):
            "\(directory.path(percentEncoded: false)) has remotes \(remotes.joined(separator: ", ")), none of them github.com/\(expected)."
        }
    }
}

/// A checkout's top level has `.git`: a directory, or a file in a worktree. Requiring it here
/// keeps a plain directory inside some other repo from passing as that repo.
private func isGitCheckout(_ directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: directory.appending(path: ".git").path(percentEncoded: false))
}
