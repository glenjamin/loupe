import Foundation
@testable import LoupeGitHub
import Testing

struct GitHubCLITests {
    @Test func prefersTheFirstCandidateThatCanBeRun() throws {
        let directory = try temporaryDirectory()
        let missing = directory.appending(path: "missing").path(percentEncoded: false)
        let unrunnable = try script(in: directory, named: "unrunnable", executable: false)
        let homebrew = try script(in: directory, named: "homebrew")
        let system = try script(in: directory, named: "system")

        let chosen = GitHubCLI.executable(environment: [:], candidates: [missing, unrunnable, homebrew, system])

        #expect(chosen?.path(percentEncoded: false) == homebrew)
    }

    @Test func leavesItToPathWhenNoCandidateCanBeRun() throws {
        let directory = try temporaryDirectory()
        let missing = directory.appending(path: "missing").path(percentEncoded: false)
        let unrunnable = try script(in: directory, named: "unrunnable", executable: false)

        #expect(GitHubCLI.executable(environment: [:], candidates: [missing, unrunnable]) == nil)
    }

    @Test func loupeGHWinsOutright() throws {
        let directory = try temporaryDirectory()
        let homebrew = try script(in: directory, named: "homebrew")
        let named = directory.appending(path: "named").path(percentEncoded: false)

        let chosen = GitHubCLI.executable(environment: ["LOUPE_GH": named], candidates: [homebrew])

        #expect(chosen?.path(percentEncoded: false) == named)
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "loupe-gh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A stand-in gh that prints a token, runnable unless `executable` is false.
private func script(in directory: URL, named name: String, executable: Bool = true) throws -> String {
    let path = directory.appending(path: name).path(percentEncoded: false)
    try "#!/bin/sh\necho fake-token\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: path)
    return path
}
