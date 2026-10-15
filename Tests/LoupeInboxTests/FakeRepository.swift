import Foundation
import Testing

/// A repo as GitHub and a reviewer's machine hold it: a bare `origin` that exposes PRs as
/// `refs/pull/<N>/head`, a contributor's clone that pushes to it, and the reviewer's `checkout`,
/// cloned before any PR existed. The checkout knows origin as `github.com/tamarinworks/app`, which
/// its config rewrites to the bare repo. Its first commit vendors a dependency, has a `go.sum`,
/// marks `gen/` as `linguist-generated`, and keeps `pinned/` and `vendor/patched/` in review
/// however they look. Deleted when the test ends.
final class FakeRepository: Sendable {
    let root: URL
    let origin: URL
    let checkout: URL
    private let contributor: URL
    /// The contributor's clone, for git commands no helper here covers.
    var contributorDirectory: URL { contributor }

    init() async throws {
        // Resolved, so paths compare equal to those git reports.
        root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory).resolvingSymlinksInPath()
        origin = root.appending(path: "origin.git", directoryHint: .isDirectory)
        checkout = root.appending(path: "checkout", directoryHint: .isDirectory)
        contributor = root.appending(path: "contributor", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contributor, withIntermediateDirectories: true)

        try await git(["init", "--quiet", "--initial-branch=main"], in: contributor)
        try await commit([
            "app.go": "package app\n\nfunc Hello() string { return \"hello\" }\n",
            "README": "An app.\n",
            "go.sum": "example.com/lib v1.0.0 h1:abc\n",
            "vendor/example.com/lib/lib.go": "package lib\n",
            "gen/schema.go": "package gen // generated\n",
            ".gitattributes": "gen/** linguist-generated=true\nvendor/patched/** linguist-vendored=false\npinned/** linguist-generated=false\n",
        ], message: "Start the app")
        try await git(["clone", "--quiet", "--bare", contributor.path(percentEncoded: false), origin.path(percentEncoded: false)], in: root)
        try await git(["remote", "add", "origin", origin.path(percentEncoded: false)], in: contributor)
        try await git(["clone", "--quiet", origin.path(percentEncoded: false), checkout.path(percentEncoded: false)], in: root)
        try await git(["remote", "set-url", "origin", "https://github.com/tamarinworks/app"], in: checkout)
        try await git(["config", "url.\(origin.path(percentEncoded: false)).insteadOf", "https://github.com/tamarinworks/app"], in: checkout)
    }

    /// Adds another bare repo holding what origin does, as remote `name` of the contributor and of
    /// the checkout, which knows it by GitHub URL `url`: the repo a fork was made from, say.
    func addRemote(_ name: String, as url: String) async throws {
        let bare = bareRepository(name)
        try await git(["clone", "--quiet", "--bare", origin.path(percentEncoded: false), bare.path(percentEncoded: false)], in: root)
        try await git(["remote", "add", name, bare.path(percentEncoded: false)], in: contributor)
        try await git(["remote", "add", name, url], in: checkout)
        try await git(["config", "url.\(bare.path(percentEncoded: false)).insteadOf", url], in: checkout)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Commits to the contributor's current branch, writing each file (nil deletes it), and
    /// returns the commit's oid.
    @discardableResult
    func commit(_ files: [String: String?], message: String) async throws -> String {
        for (path, contents) in files {
            let url = contributor.appending(path: path)
            if let contents {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
        try await git(["add", "--all"], in: contributor)
        try await git(["commit", "--quiet", "-m", message], in: contributor)
        return try await git(["rev-parse", "HEAD"], in: contributor)
    }

    /// Moves `git mv`-style, so the commit records a rename.
    @discardableResult
    func rename(_ from: String, to: String, message: String) async throws -> String {
        try await git(["mv", from, to], in: contributor)
        try await git(["commit", "--quiet", "-m", message], in: contributor)
        return try await git(["rev-parse", "HEAD"], in: contributor)
    }

    func switchTo(_ branch: String, creatingFrom start: String? = nil) async throws {
        try await git(["switch", "--quiet"] + (start.map { ["-c", branch, $0] } ?? [branch]), in: contributor)
    }

    /// Pushes the current branch to `remote`, and as PR `number`'s head if given, as GitHub does.
    func push(asPullRequest number: Int? = nil, to remote: String = "origin") async throws {
        let branch = try await git(["branch", "--show-current"], in: contributor)
        try await git(["push", "--quiet", "--force", remote, "HEAD:refs/heads/\(branch)"], in: contributor)
        if let number {
            try await git(["update-ref", "refs/pull/\(number)/head", git(["rev-parse", "HEAD"], in: contributor)], in: bareRepository(remote))
        }
    }

    /// What the reviewer's checkout has checked out and staged, which Loupe must leave alone.
    func checkoutState() async throws -> String {
        try await git(["rev-parse", "HEAD"], in: checkout) + " " + git(["branch", "--show-current"], in: checkout) + " " + git(["status", "--porcelain"], in: checkout)
    }

    /// git's trimmed stdout, isolated from the user's git config.
    @discardableResult
    func git(_ arguments: [String], in directory: URL) async throws -> String {
        try await runGit(arguments, in: directory)
    }

    private func bareRepository(_ remote: String) -> URL {
        root.appending(path: "\(remote).git", directoryHint: .isDirectory)
    }
}

/// git's trimmed stdout, isolated from the user's git config. Runs on a background queue, as it
/// blocks until git exits, so a test on the main actor doesn't hold up others waiting for it.
@discardableResult
func runGit(_ arguments: [String], in directory: URL) async throws -> String {
    let (status, output) = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try runGitBlocking(arguments, in: directory) })
        }
    }
    try #require(status == 0, "git \(arguments.joined(separator: " ")) failed")
    return output
}

private func runGitBlocking(_ arguments: [String], in directory: URL) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", directory.path(percentEncoded: false)] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_AUTHOR_NAME"] = "Contributor"
    environment["GIT_AUTHOR_EMAIL"] = "contributor@example.com"
    environment["GIT_COMMITTER_NAME"] = "Contributor"
    environment["GIT_COMMITTER_EMAIL"] = "contributor@example.com"
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
