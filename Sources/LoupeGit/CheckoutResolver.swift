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

    /// Stores `directory` as the checkout of `repository`, if it is one: a git repo whose `origin`
    /// is that repo on GitHub.
    public func locate(_ repository: String, at directory: URL) async throws -> URL {
        let directory = directory.standardizedFileURL
        guard isGitCheckout(directory) else { throw CheckoutError.notAGitRepository(directory) }
        let origin = try? await Git.originURL(of: directory)
        guard let origin, GitHubRemote(url: origin)?.matches(repository) == true else {
            throw CheckoutError.differentOrigin(directory, expected: repository, origin: origin)
        }
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: repository, path: directory, verifiedAt: .now)])
        return directory
    }

    /// The first directory named after the repo under a search root whose `origin` is that repo.
    /// Other copies, like worktrees named `<repo>-<branch>`, aren't considered.
    private func search(for repository: String) async throws -> URL? {
        guard let name = repository.split(separator: "/").last else { return nil }
        for root in searchRoots {
            let candidate = root.appending(path: String(name), directoryHint: .isDirectory)
            guard isGitCheckout(candidate),
                  let origin = try? await Git.originURL(of: candidate),
                  GitHubRemote(url: origin)?.matches(repository) == true
            else { continue }
            return candidate
        }
        return nil
    }
}

public enum CheckoutError: Error, LocalizedError, Equatable {
    case notAGitRepository(URL)
    case differentOrigin(URL, expected: String, origin: String?)

    public var errorDescription: String? {
        switch self {
        case let .notAGitRepository(directory):
            "\(directory.path(percentEncoded: false)) isn't a git repository."
        case let .differentOrigin(directory, expected, origin?):
            "\(directory.path(percentEncoded: false)) is a checkout of \(origin), not github.com/\(expected)."
        case let .differentOrigin(directory, expected, nil):
            "\(directory.path(percentEncoded: false)) has no origin remote, so it can't be confirmed as github.com/\(expected)."
        }
    }
}

/// A checkout's top level has `.git`: a directory, or a file in a worktree. Requiring it here
/// keeps a plain directory inside some other repo from passing as that repo.
private func isGitCheckout(_ directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: directory.appending(path: ".git").path(percentEncoded: false))
}
