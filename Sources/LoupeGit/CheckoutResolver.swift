import Foundation
import LoupeStore

/// Finds where GitHub repos are checked out on this machine, remembering what it finds in the
/// store. Only ever reads from the checkouts, though it can clone a repo that has none.
public struct CheckoutResolver: Sendable {
    /// Directories searched, in order, for a checkout named after a repo that has none stored.
    public var searchRoots: [URL]
    private let store: PullRequestStore
    /// Config a clone is made with, as `git clone --config` sets it in the new checkout; tests
    /// rewrite github.com to a local repo with it.
    private let cloneConfig: [String: String]

    public init(store: PullRequestStore, searchRoots: [URL], cloneConfig: [String: String] = [:]) {
        self.store = store
        self.searchRoots = searchRoots
        self.cloneConfig = cloneConfig
    }

    /// Where a clone of `repository` goes: under the search root named after its owner, as
    /// `~/Development/tamarinworks` would be for tamarinworks' repos, else under the last one,
    /// which holds everyone else's. Nil with no search roots.
    public func cloneDestination(for repository: String) -> URL? {
        let parts = repository.split(separator: "/")
        guard let name = parts.last, let fallback = searchRoots.last else { return nil }
        let owner = parts.count > 1 ? String(parts[0]) : ""
        let root = searchRoots.first { $0.lastPathComponent.caseInsensitiveCompare(owner) == .orderedSame } ?? fallback
        return root.appending(path: String(name), directoryHint: .isDirectory)
    }

    /// Clones `repository` from github.com over https, as the user's own checkouts are, to its
    /// `cloneDestination` and stores it as the repo's checkout. git's progress goes to `progress`
    /// as it comes. The clone is made in a hidden sibling directory and only renamed into place
    /// once complete, so a failure or cancellation leaves nothing behind, and an existing
    /// directory of that name is never touched.
    public func clone(_ repository: String, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard let destination = cloneDestination(for: repository) else { throw CheckoutError.nowhereToClone(repository) }
        let root = destination.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else { throw CheckoutError.alreadyExists(destination) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let partial = root.appending(path: ".\(destination.lastPathComponent).loupe-clone-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        do {
            let config = cloneConfig.sorted { $0.key < $1.key }.flatMap { ["--config", "\($0.key)=\($0.value)"] }
            try await Git.runReportingProgress(["clone", "--progress"] + config + ["https://github.com/\(repository)", partial.path(percentEncoded: false)], in: root, timeout: .seconds(3600), progress: progress)
            try Task.checkCancellation()
            // Fails rather than replacing a directory made meanwhile.
            do {
                try fileManager.moveItem(at: partial, to: destination)
            } catch {
                throw fileManager.fileExists(atPath: destination.path(percentEncoded: false)) ? CheckoutError.alreadyExists(destination) : error
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        return try await locate(repository, at: destination)
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
    /// A clone's destination is taken, by anything.
    case alreadyExists(URL)
    /// There are no search roots to clone under.
    case nowhereToClone(String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyExists(directory):
            "\(directory.path(percentEncoded: false)) already exists, so it was left alone. Locate it if it's a checkout."
        case let .nowhereToClone(repository):
            "There's nowhere set to clone \(repository) into."
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
