import Foundation
@testable import LoupeGit
import Testing

struct GitTests {
    @Test func runsAGitThatAnswers() async throws {
        let directory = try temporaryDirectory()

        let version = try await Git.run(["--version"], in: directory)

        #expect(FileManager.default.isExecutableFile(atPath: Git.executable.path(percentEncoded: false)))
        #expect(version.hasPrefix("git version "))
    }

    @Test func prefersTheFirstCandidateThatCanBeRun() throws {
        let directory = try temporaryDirectory()
        let missing = directory.appending(path: "missing").path(percentEncoded: false)
        let unrunnable = try script(in: directory, named: "unrunnable", executable: false)
        let homebrew = try script(in: directory, named: "homebrew")
        let apple = try script(in: directory, named: "apple")

        let chosen = Git.executable(environment: [:], candidates: [missing, unrunnable, homebrew, apple])

        #expect(chosen.path(percentEncoded: false) == homebrew)
    }

    @Test func loupeGitWinsOutright() throws {
        let directory = try temporaryDirectory()
        let homebrew = try script(in: directory, named: "homebrew")
        let named = directory.appending(path: "named").path(percentEncoded: false)

        let chosen = Git.executable(environment: ["LOUPE_GIT": named], candidates: [homebrew])

        #expect(chosen.path(percentEncoded: false) == named)
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "loupe-git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A stand-in git that execs `/usr/bin/git`, runnable unless `executable` is false.
private func script(in directory: URL, named name: String, executable: Bool = true) throws -> String {
    let path = directory.appending(path: name).path(percentEncoded: false)
    try "#!/bin/sh\nexec /usr/bin/git \"$@\"\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: path)
    return path
}
