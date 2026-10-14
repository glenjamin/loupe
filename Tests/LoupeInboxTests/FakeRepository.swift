import Foundation
import Testing

/// A repo as GitHub and a reviewer's machine hold it: a bare `origin` that exposes PRs as
/// `refs/pull/<N>/head`, a contributor's clone that pushes to it, and the reviewer's `checkout`,
/// cloned before any PR existed. Its first commit vendors a dependency, has a `go.sum`, and marks
/// `gen/` as `linguist-generated`. Deleted when the test ends.
final class FakeRepository {
    let root: URL
    let origin: URL
    let checkout: URL
    private let contributor: URL

    init() throws {
        // Resolved, so paths compare equal to those git reports.
        root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory).resolvingSymlinksInPath()
        origin = root.appending(path: "origin.git", directoryHint: .isDirectory)
        checkout = root.appending(path: "checkout", directoryHint: .isDirectory)
        contributor = root.appending(path: "contributor", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contributor, withIntermediateDirectories: true)

        try git(["init", "--quiet", "--initial-branch=main"], in: contributor)
        try commit([
            "app.go": "package app\n\nfunc Hello() string { return \"hello\" }\n",
            "README": "An app.\n",
            "go.sum": "example.com/lib v1.0.0 h1:abc\n",
            "vendor/example.com/lib/lib.go": "package lib\n",
            "gen/schema.go": "package gen // generated\n",
            ".gitattributes": "gen/** linguist-generated=true\nvendor/patched/** linguist-vendored=false\n",
        ], message: "Start the app")
        try git(["clone", "--quiet", "--bare", contributor.path(percentEncoded: false), origin.path(percentEncoded: false)], in: root)
        try git(["remote", "add", "origin", origin.path(percentEncoded: false)], in: contributor)
        try git(["clone", "--quiet", origin.path(percentEncoded: false), checkout.path(percentEncoded: false)], in: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Commits to the contributor's current branch, writing each file (nil deletes it), and
    /// returns the commit's oid.
    @discardableResult
    func commit(_ files: [String: String?], message: String) throws -> String {
        for (path, contents) in files {
            let url = contributor.appending(path: path)
            if let contents {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
        try git(["add", "--all"], in: contributor)
        try git(["commit", "--quiet", "-m", message], in: contributor)
        return try git(["rev-parse", "HEAD"], in: contributor)
    }

    /// Moves `git mv`-style, so the commit records a rename.
    @discardableResult
    func rename(_ from: String, to: String, message: String) throws -> String {
        try git(["mv", from, to], in: contributor)
        try git(["commit", "--quiet", "-m", message], in: contributor)
        return try git(["rev-parse", "HEAD"], in: contributor)
    }

    func switchTo(_ branch: String, creatingFrom start: String? = nil) throws {
        try git(["switch", "--quiet"] + (start.map { ["-c", branch, $0] } ?? [branch]), in: contributor)
    }

    /// Pushes the current branch to origin, and as PR `number`'s head if given, as GitHub does.
    func push(asPullRequest number: Int? = nil) throws {
        let branch = try git(["branch", "--show-current"], in: contributor)
        try git(["push", "--quiet", "--force", "origin", "HEAD:refs/heads/\(branch)"], in: contributor)
        if let number {
            try git(["update-ref", "refs/pull/\(number)/head", try git(["rev-parse", "HEAD"], in: contributor)], in: origin)
        }
    }

    /// What the reviewer's checkout has checked out and staged, which Loupe must leave alone.
    func checkoutState() throws -> String {
        try git(["rev-parse", "HEAD"], in: checkout) + " " + git(["branch", "--show-current"], in: checkout) + " " + git(["status", "--porcelain"], in: checkout)
    }

    /// git's trimmed stdout, isolated from the user's git config.
    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
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
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
