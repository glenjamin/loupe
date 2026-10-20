import Foundation
@testable import LoupeInbox
import Testing

struct CircleCIArtifactsTests {
    @Test func theFirstOpenDownloadsTheJobAndServesTheReportFromDisk() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let artifacts = circleCI.artifacts()
        let progress = ProgressLog()

        let page = try await artifacts.open(reportURL) { progress.append($0) }

        #expect(page.absoluteString == "loupe-artifact://output.circle-artifacts.com/output/job/\(job)/artifacts/0/diff-book/review/index.html")
        #expect(artifacts.contents(of: page)?.data == Data(reportFiles["diff-book/review/index.html"]!.utf8))
        #expect(artifacts.contents(of: page)?.mimeType == "text/html")
        // The page's relative files resolve under the same scheme, so they're served too.
        let image = try #require(URL(string: "images/after-buttons--primary.png", relativeTo: page)?.absoluteURL)
        #expect(artifacts.contents(of: image)?.data == Data("png".utf8))
        #expect(artifacts.contents(of: image)?.mimeType == "image/png")
        #expect(progress.values.first == CircleCIArtifacts.Progress(done: 0, total: nil))
        #expect(progress.values.last == CircleCIArtifacts.Progress(done: 3, total: 3))
        #expect(circleCI.calls == ["artifact \(job) --output"])
    }

    @Test func aDownloadedJobOpensFromTheCacheWithoutTheCLI() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        _ = try await circleCI.artifacts().open(reportURL)

        // Next run, with the CLI gone even, the job is already on disk.
        let later = CircleCIArtifacts(cache: circleCI.cache, environment: ["LOUPE_CIRCLECI": "/nonexistent/circleci"])
        let progress = ProgressLog()
        let page = try await later.open(reportURL) { progress.append($0) }

        #expect(later.contents(of: page) != nil)
        #expect(progress.values.isEmpty, "nothing to download")
        #expect(circleCI.calls.count == 1)
    }

    @Test func anInterruptedDownloadIsNeverServed() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        circleCI.failAfter(files: 1)
        let artifacts = circleCI.artifacts()

        await #expect(throws: CircleCIArtifacts.Failure.failed("connection reset by peer")) {
            try await artifacts.open(reportURL)
        }
        #expect(artifacts.contents(of: try #require(CircleCIArtifacts.proxyURL(for: reportURL))) == nil)
        #expect(try circleCI.cachedEntries() == [], "the partial download is cleared away")

        circleCI.failAfter(files: nil)
        let page = try await artifacts.open(reportURL)
        #expect(artifacts.contents(of: page) != nil)
        #expect(circleCI.calls.count == 2, "downloaded afresh")
    }

    @Test func aCancelledDownloadStopsTheCLIAndLeavesNothing() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        circleCI.slow()
        let artifacts = circleCI.artifacts()
        let progress = ProgressLog()

        let opening = Task { try await artifacts.open(reportURL) { progress.append($0) } }
        while !progress.values.contains(where: { $0.done > 0 }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(progress.values.last?.total == 3, "the CLI said how many it would fetch")
        opening.cancel()

        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(try circleCI.cachedEntries() == [])
    }

    @Test func aDownloadLeftUnfinishedByACrashIsNotUsedAndIsPrunedLater() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let leftover = circleCI.cache.appending(path: ".partial-\(job)-crashed")
        try write(["diff-book/review/index.html": "half"], into: leftover)
        try setModified(leftover, daysAgo: 2)
        let artifacts = circleCI.artifacts()

        let page = try await artifacts.open(reportURL)

        #expect(artifacts.contents(of: page)?.data == Data(reportFiles["diff-book/review/index.html"]!.utf8))
        #expect(circleCI.calls.count == 1)
        #expect(try circleCI.cachedEntries() == [job], "downloading pruned what the crash left")
    }

    @Test func withoutTheCLITheMessageSaysHowToInstallIt() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let artifacts = CircleCIArtifacts(cache: circleCI.cache, environment: ["LOUPE_CIRCLECI": circleCI.root.appending(path: "missing").path(percentEncoded: false)])

        let failure = await failure { try await artifacts.open(reportURL) }

        #expect(failure == .cliMissing)
        #expect(failure?.message.contains("`brew install circleci`") == true)
        #expect(try circleCI.cachedEntries() == [])
    }

    @Test func aSignedOutCLIIsAskedToSignIn() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles], isSignedIn: false)

        let failure = await failure { try await circleCI.artifacts().open(reportURL) }

        #expect(failure == .refused("No CircleCI API token found."))
        #expect(failure?.title == "The circleci CLI isn't signed in")
        #expect(failure?.message.contains("`circleci auth login`") == true)
        #expect(try circleCI.cachedEntries() == [])
    }

    @Test func aFailedDownloadSaysWhatTheCLISaid() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [:])

        let failure = await failure { try await circleCI.artifacts().open(reportURL) }

        #expect(failure == .failed("No resource found for \"\(job)\"."))
        #expect(failure?.title == "Couldn't download the report")
    }

    @Test func aJobWithoutTheReportSaysSo() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: ["diff-book/playwright-report/index.html": "playwright"]])

        let failure = await failure { try await circleCI.artifacts().open(reportURL) }

        #expect(failure == .missing(path: "diff-book/review/index.html"))
    }

    @Test func jobsUnopenedForAMonthArePruned() async throws {
        let stale = "22222222-2222-4333-8444-555555555555"
        let recent = "33333333-2222-4333-8444-555555555555"
        let circleCI = try FakeCircleCICLI(jobs: [:])
        for (job, days) in [(job, 40), (stale, 31), (recent, 29)] {
            let directory = circleCI.cache.appending(path: job)
            try write(reportFiles, into: directory)
            try setModified(directory, daysAgo: days)
        }
        let artifacts = circleCI.artifacts()

        // Opening counts as use, however long ago it was downloaded.
        _ = try await artifacts.open(reportURL)
        artifacts.prune()

        #expect(try circleCI.cachedEntries() == [job, recent])
        #expect(circleCI.calls.isEmpty)
    }

    @Test func onlyTheJobsOwnFilesAreServed() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let artifacts = circleCI.artifacts()
        let page = try await artifacts.open(reportURL)
        try "secret".write(to: circleCI.root.appending(path: "outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: circleCI.cache.appending(path: "\(job)/diff-book/review/link.txt"), withDestinationURL: circleCI.root.appending(path: "outside.txt"))

        #expect(CircleCIArtifacts.proxyURL(for: try #require(URL(string: "https://example.com/index.html"))) == nil)
        #expect(CircleCIArtifacts.proxyURL(for: try #require(URL(string: "http://output.circle-artifacts.com/output/job/\(job)/artifacts/0/x.html"))) == nil)
        await #expect(throws: CircleCIArtifacts.Failure.notAnArtifact(host: "example.com")) {
            try await artifacts.open(try #require(URL(string: "https://example.com/index.html")))
        }
        for escape in ["../../../../../outside.txt", "%2E%2E/%2E%2E/%2E%2E/%2E%2E/%2E%2E/outside.txt", "link.txt"] {
            let url = try #require(URL(string: escape, relativeTo: page)?.absoluteURL)
            #expect(artifacts.contents(of: url) == nil, "\(escape)")
        }
        #expect(artifacts.contents(of: try #require(URL(string: "loupe-artifact://example.com/output/job/\(job)/artifacts/0/diff-book/review/index.html"))) == nil)
    }

    @Test func theCLIIsFoundOnPathWhenNotWhereHomebrewPutsIt() throws {
        let circleCI = try FakeCircleCICLI(jobs: [:])
        let bin = circleCI.executable.deletingLastPathComponent().path(percentEncoded: false)
        let named = circleCI.root.appending(path: "named").path(percentEncoded: false)

        #expect(CircleCIArtifacts.executable(environment: ["PATH": "/nonexistent:\(bin)"], candidates: ["/nonexistent/circleci"]) == circleCI.executable)
        #expect(CircleCIArtifacts.executable(environment: ["PATH": "/nonexistent"], candidates: []) == nil)
        #expect(CircleCIArtifacts.executable(environment: ["LOUPE_CIRCLECI": named, "PATH": bin], candidates: []) == URL(filePath: named))
    }
}

private let job = "11111111-2222-4333-8444-555555555555"
private let reportURL = URL(string: "https://output.circle-artifacts.com/output/job/\(job)/artifacts/0/diff-book/review/index.html")!
private let reportFiles = [
    "diff-book/review/index.html": "<img src=images/after-buttons--primary.png>",
    "diff-book/review/images/after-buttons--primary.png": "png",
    "diff-book/playwright-report/index.html": "playwright",
]

/// The `circleci` CLI over a made-up CircleCI: `artifact <job> --output <dir>` announces how many
/// artifacts the job has, then copies each into the directory by path, as the real one does. It
/// fails as the real one does when it isn't signed in or the job is unknown, and can be made to
/// drop its connection part way or to go slowly. Each run is logged.
private final class FakeCircleCICLI: Sendable {
    let root: URL
    let cache: URL
    let executable: URL

    init(jobs: [String: [String: String]], isSignedIn: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "loupe-circleci-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = root.appending(path: "cache", directoryHint: .isDirectory)
        executable = root.appending(path: "bin/circleci")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (job, files) in jobs {
            try write(files, into: root.appending(path: "jobs/\(job)"))
        }
        if isSignedIn { try flag("signed-in", "") }
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
    }

    func artifacts() -> CircleCIArtifacts {
        CircleCIArtifacts(cache: cache, environment: ["LOUPE_CIRCLECI": executable.path(percentEncoded: false)])
    }

    /// Each run's arguments, the output directory left off as it's made up each time.
    var calls: [String] {
        let log = (try? String(contentsOf: root.appending(path: "calls.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map { String($0.split(separator: " ").prefix(3).joined(separator: " ")) }
    }

    func failAfter(files: Int?) {
        if let files { try? flag("fail-after", "\(files)") } else { try? FileManager.default.removeItem(at: root.appending(path: "fail-after")) }
    }

    func slow() {
        try? flag("slow", "")
    }

    /// What's in the cache: each job's directory and anything else left there.
    func cachedEntries() throws -> [String] {
        guard FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: cache.path(percentEncoded: false)).sorted()
    }

    private func flag(_ name: String, _ value: String) throws {
        try value.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
    }

    private static let script = #"""
        #!/bin/sh
        root="$(cd "$(dirname "$0")/.." && pwd)"
        echo "$*" >> "$root/calls.log"
        if [ "$1" != artifact ] || [ "$3" != --output ]; then echo "error: unexpected arguments: $*" >&2; exit 2; fi
        job="$2"; out="$4"
        if [ ! -f "$root/signed-in" ]; then
          printf 'error: No CircleCI API token found.\n\nSuggestions:\n  • Run: circleci auth login\n' >&2; exit 3
        fi
        if [ ! -d "$root/jobs/$job" ]; then echo "error: No resource found for \"$job\"." >&2; exit 5; fi
        files=$(cd "$root/jobs/$job" && find . -type f | sed 's|^\./||' | sort)
        count=$(printf '%s\n' "$files" | grep -c .)
        echo "Downloading $count artifact(s) to \"$out\"..." >&2
        n=0
        for f in $files; do
          if [ -f "$root/fail-after" ] && [ "$n" -ge "$(cat "$root/fail-after")" ]; then echo "error: connection reset by peer" >&2; exit 1; fi
          mkdir -p "$out/$(dirname "$f")"
          cp "$root/jobs/$job/$f" "$out/$f"
          n=$((n + 1))
          if [ -f "$root/slow" ]; then sleep 1; fi
        done
        echo "✓ Downloaded $count artifact(s)" >&2
        """#
}

/// Collects the progress a download reports, from whichever thread reports it.
private final class ProgressLog: @unchecked Sendable {
    private var reported: [CircleCIArtifacts.Progress] = []
    private let lock = NSLock()

    func append(_ progress: CircleCIArtifacts.Progress) {
        lock.withLock { reported.append(progress) }
    }

    var values: [CircleCIArtifacts.Progress] {
        lock.withLock { reported }
    }
}

private func failure(_ body: () async throws -> URL) async -> CircleCIArtifacts.Failure? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error as? CircleCIArtifacts.Failure
    }
}

private func write(_ files: [String: String], into directory: URL) throws {
    for (path, contents) in files {
        let file = directory.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
}

private func setModified(_ url: URL, daysAgo days: Int) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)], ofItemAtPath: url.path(percentEncoded: false))
}
