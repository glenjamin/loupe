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
        #expect(await artifacts.serve(page).data == Data(reportFiles["diff-book/review/index.html"]!.utf8))
        #expect(await artifacts.serve(page).mimeType == "text/html")
        // The page's relative files resolve under the same scheme, so they're served too.
        let image = try #require(URL(string: "images/after-buttons--primary.png", relativeTo: page)?.absoluteURL)
        #expect(await artifacts.serve(image).data == Data("png".utf8))
        #expect(await artifacts.serve(image).mimeType == "image/png")
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

        #expect(await later.serve(page).status == 200)
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
        let proxied = try #require(CircleCIArtifacts.proxyURL(for: reportURL))
        #expect(await artifacts.serve(proxied).status == 404)
        #expect(try circleCI.cachedEntries() == [], "the partial download is cleared away")

        circleCI.failAfter(files: nil)
        let page = try await artifacts.open(reportURL)
        #expect(await artifacts.serve(page).status == 200)
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

        #expect(await artifacts.serve(page).data == Data(reportFiles["diff-book/review/index.html"]!.utf8))
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
            #expect(await artifacts.serve(url).status == 404, "\(escape)")
        }
        let elsewhere = try #require(URL(string: "loupe-artifact://example.com/output/job/\(job)/artifacts/0/diff-book/review/index.html"))
        #expect(await artifacts.serve(elsewhere).status == 404)
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

/// Signed in, so the `circleci` CLI's token can be read: each file is fetched as it's asked for.
struct CircleCIOnDemandTests {
    @Test func theReportIsFetchedWithTheCLIsTokenAsThePageAsksForIt() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let host = FakeCircleCIHost(jobs: [job: reportFiles], accepting: ["token-a"])
        let token = try FakeTokenCommand(in: circleCI.root, printing: "token-a")
        let artifacts = circleCI.artifacts(token: token, host: host)
        let progress = ProgressLog()

        let page = try await artifacts.open(reportURL) { progress.append($0) }

        #expect(page == CircleCIArtifacts.proxyURL(for: reportURL))
        #expect(await artifacts.serve(page).data == Data(reportFiles["diff-book/review/index.html"]!.utf8))
        let image = try #require(URL(string: "images/after-buttons--primary.png", relativeTo: page)?.absoluteURL)
        #expect(await artifacts.serve(image) == CircleCIArtifacts.Served(status: 200, data: Data("png".utf8), mimeType: "image/png"))
        #expect(host.requests.map(\.path) == ["diff-book/review/index.html", "diff-book/review/images/after-buttons--primary.png"])
        #expect(host.requests.allSatisfy { $0.token == "token-a" })
        #expect(circleCI.calls.isEmpty, "the CLI downloads nothing")
        #expect(progress.values.isEmpty, "no download to show")
        #expect(token.runs == 1)
        #expect(try circleCI.cachedFiles() == ["diff-book/review/images/after-buttons--primary.png", "diff-book/review/index.html"], "only what was asked for")
    }

    @Test func fetchedFilesAreKeptSoReopeningFetchesNothing() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let host = FakeCircleCIHost(jobs: [job: reportFiles], accepting: ["token-a"])
        let token = try FakeTokenCommand(in: circleCI.root, printing: "token-a")
        let page = try await circleCI.artifacts(token: token, host: host).open(reportURL)
        let image = try #require(URL(string: "images/after-buttons--primary.png", relativeTo: page)?.absoluteURL)
        _ = await circleCI.artifacts(token: token, host: host).serve(image)

        // Next run, signed out and with CircleCI unreachable even, what was fetched is on disk.
        token.signOut()
        let later = circleCI.artifacts(token: token, host: FakeCircleCIHost(jobs: [:], accepting: []))
        #expect(try await later.open(reportURL) == page)
        #expect(await later.serve(image).data == Data("png".utf8))
        #expect(host.requests.count == 2)
        #expect(circleCI.calls.isEmpty)
    }

    @Test func theTokenGoesOnlyToCircleCIAcrossRedirects() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let host = FakeCircleCIHost(jobs: [job: reportFiles], accepting: ["token-a"], throughApp: true, offHost: ["diff-book/review/images/after-buttons--primary.png"])
        let artifacts = circleCI.artifacts(token: try FakeTokenCommand(in: circleCI.root, printing: "token-a"), host: host)

        let page = try await artifacts.open(reportURL)
        let image = try #require(URL(string: "images/after-buttons--primary.png", relativeTo: page)?.absoluteURL)
        #expect(await artifacts.serve(image).data == Data("png".utf8))

        #expect(host.requests.map(\.host) == ["output.circle-artifacts.com", "app.circleci.com", "output.circle-artifacts.com", "app.circleci.com", "storage.example.com"])
        #expect(host.requests.map(\.token) == ["token-a", "token-a", "token-a", "token-a", nil], "kept within CircleCI, dropped off it")
    }

    @Test func aTokenTurnedDownIsReadAgainOnce() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let host = FakeCircleCIHost(jobs: [job: reportFiles], accepting: ["token-a"])
        let token = try FakeTokenCommand(in: circleCI.root, printing: "token-a")
        let artifacts = circleCI.artifacts(token: token, host: host)
        let page = try await artifacts.open(reportURL)

        // Signed in again since: the old token is refused and the CLI keeps a new one.
        host.accept(["token-b"])
        try token.store("token-b")
        let image = try #require(URL(string: "images/after-buttons--primary.png", relativeTo: page)?.absoluteURL)
        #expect(await artifacts.serve(image).status == 200)
        #expect(host.requests.suffix(2).map(\.token) == ["token-a", "token-b"])
        #expect(token.runs == 2)

        // Turned down outright: read again once, then answered as CircleCI answered.
        host.accept([])
        let other = try #require(URL(string: "other.png", relativeTo: page)?.absoluteURL)
        #expect(await artifacts.serve(other).status == 401)
        #expect(await artifacts.serve(other).status == 401)
        #expect(token.runs == 3)
    }

    @Test func aTokenTurnedDownOnOpeningAsksToSignIn() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let host = FakeCircleCIHost(jobs: [job: reportFiles], accepting: [])
        let token = try FakeTokenCommand(in: circleCI.root, printing: "expired")

        let failure = await failure { try await circleCI.artifacts(token: token, host: host).open(reportURL) }

        #expect(failure == .refused("CircleCI turned down the token the circleci CLI is signed in with."))
        #expect(failure?.message.contains("`circleci auth login`") == true)
        #expect(token.runs == 2, "read again once")
        #expect(circleCI.calls.isEmpty)
    }

    @Test func aReportCircleCIHasntSaysSo() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [:])
        let token = try FakeTokenCommand(in: circleCI.root, printing: "token-a")
        let artifacts = circleCI.artifacts(token: token, host: FakeCircleCIHost(jobs: [job: [:]], accepting: ["token-a"]))

        let failure = await failure { try await artifacts.open(reportURL) }

        #expect(failure == .missing(path: "diff-book/review/index.html"))
    }

    @Test func signedOutTheCLIDownloadsTheWholeJob() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let host = FakeCircleCIHost(jobs: [job: reportFiles], accepting: ["token-a"])
        let token = try FakeTokenCommand(in: circleCI.root, printing: nil)
        let artifacts = circleCI.artifacts(token: token, host: host)
        let progress = ProgressLog()

        let page = try await artifacts.open(reportURL) { progress.append($0) }

        #expect(await artifacts.serve(page).data == Data(reportFiles["diff-book/review/index.html"]!.utf8))
        #expect(circleCI.calls == ["artifact \(job) --output"])
        #expect(progress.values.last == CircleCIArtifacts.Progress(done: 3, total: 3))
        #expect(host.requests.isEmpty, "nothing fetched without a token")
        #expect(token.runs == 1)
    }

    @Test func aDownloadAfterSigningOutSupersedesFilesFetchedBefore() async throws {
        let circleCI = try FakeCircleCICLI(jobs: [job: reportFiles])
        let host = FakeCircleCIHost(jobs: [job: reportFiles], accepting: ["token-a"])
        let token = try FakeTokenCommand(in: circleCI.root, printing: "token-a")
        let fetched = try await circleCI.artifacts(token: token, host: host).open(reportURL)
        let image = try #require(URL(string: "images/after-buttons--primary.png", relativeTo: fetched)?.absoluteURL)
        // Another report of the same job, never fetched, opened once signed out.
        let other = try #require(URL(string: "https://output.circle-artifacts.com/output/job/\(job)/artifacts/0/diff-book/playwright-report/index.html"))
        token.signOut()

        let page = try await circleCI.artifacts(token: token, host: host).open(other)

        #expect(await circleCI.artifacts(token: token, host: host).serve(page).data == Data("playwright".utf8))
        #expect(await circleCI.artifacts(token: token, host: host).serve(image).data == Data("png".utf8))
        #expect(try circleCI.cachedFiles().count == 3, "the whole job")
        #expect(host.requests.count == 1)
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

    /// With the CLI's token read by `token`, and CircleCI's hosts answered by `host`.
    func artifacts(token: FakeTokenCommand, host: FakeCircleCIHost) -> CircleCIArtifacts {
        let environment = ["LOUPE_CIRCLECI": executable.path(percentEncoded: false), "LOUPE_CIRCLECI_TOKEN_COMMAND": token.executable.path(percentEncoded: false)]
        return CircleCIArtifacts(cache: cache, environment: environment, transport: host.transport)
    }

    /// The paths of the files kept for the job.
    func cachedFiles() throws -> [String] {
        let directory = cache.appending(path: job, directoryHint: .isDirectory).resolvingSymlinksInPath()
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return files.compactMap { entry -> String? in
            guard let url = entry as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return url.resolvingSymlinksInPath().pathComponents.dropFirst(directory.pathComponents.count).joined(separator: "/")
        }.sorted()
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

/// The script that prints the token the CLI is signed in with: what was last stored, or a failure
/// when signed out. Each run is counted.
private final class FakeTokenCommand: Sendable {
    let executable: URL
    private let directory: URL

    init(in root: URL, printing token: String?) throws {
        directory = root.appending(path: "token", directoryHint: .isDirectory)
        executable = directory.appending(path: "circleci-token")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
        if let token { try store(token) }
    }

    func store(_ token: String) throws {
        try "\(token)\n".write(to: directory.appending(path: "stored"), atomically: true, encoding: .utf8)
    }

    func signOut() {
        try? FileManager.default.removeItem(at: directory.appending(path: "stored"))
    }

    var runs: Int {
        ((try? String(contentsOf: directory.appending(path: "runs.log"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private static let script = #"""
        #!/bin/sh
        dir="$(cd "$(dirname "$0")" && pwd)"
        echo run >> "$dir/runs.log"
        if [ ! -f "$dir/stored" ]; then echo "The circleci CLI isn't signed in." >&2; exit 1; fi
        cat "$dir/stored"
        """#
}

/// CircleCI's artifact hosts, as they answer one request each, redirects unfollowed. The artifact
/// host serves a file to an accepted `Circle-Token`, turns any other down, and without one sends
/// the request on to `app.circleci.com`, which answers 404 without a token, as for a private
/// project, and may itself send a file on to storage off CircleCI. `throughApp` sends every
/// request on to the app host. Each request is logged.
private final class FakeCircleCIHost: @unchecked Sendable {
    struct Request: Equatable {
        let host: String
        let path: String
        let token: String?
    }

    private let jobs: [String: [String: String]]
    private let throughApp: Bool
    private let offHost: Set<String>
    private let lock = NSLock()
    private var accepted: Set<String>
    private var made: [Request] = []

    init(jobs: [String: [String: String]], accepting: Set<String>, throughApp: Bool = false, offHost: Set<String> = []) {
        self.jobs = jobs
        accepted = accepting
        self.throughApp = throughApp
        self.offHost = offHost
    }

    func accept(_ tokens: Set<String>) {
        lock.withLock { accepted = tokens }
    }

    var requests: [Request] {
        lock.withLock { made }
    }

    var transport: CircleCIArtifacts.Transport {
        { [self] request in try answer(request) }
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host() else { throw URLError(.badURL) }
        let parts = url.pathComponents.filter { $0 != "/" }
        let token = request.value(forHTTPHeaderField: "Circle-Token")
        // Where each host keeps the job's id and the artifact's path.
        let (jobIndex, pathIndex) = switch host {
        case "output.circle-artifacts.com": (2, 5)
        case "app.circleci.com": (3, 6)
        case "storage.example.com": (0, 1)
        default: throw URLError(.cannotFindHost)
        }
        guard parts.count > pathIndex else { return respond(url, 404) }
        let job = parts[jobIndex]
        let path = parts.dropFirst(pathIndex).joined(separator: "/")
        let isAccepted = lock.withLock {
            made.append(Request(host: host, path: path, token: token))
            return token.map(accepted.contains) ?? false
        }
        switch host {
        case "output.circle-artifacts.com":
            if throughApp || token == nil { return respond(url, 307, location: "https://app.circleci.com/private/output/job/\(job)/artifacts/0/\(path)") }
            return isAccepted ? file(url, job, path) : respond(url, 401)
        case "app.circleci.com":
            guard token != nil else { return respond(url, 404) }
            guard isAccepted else { return respond(url, 401) }
            if offHost.contains(path) { return respond(url, 307, location: "https://storage.example.com/\(job)/\(path)") }
            return file(url, job, path)
        default:
            return file(url, job, path)
        }
    }

    private func file(_ url: URL, _ job: String, _ path: String) -> (Data, HTTPURLResponse) {
        guard let contents = jobs[job]?[path] else { return respond(url, 404) }
        return respond(url, 200, body: contents)
    }

    private func respond(_ url: URL, _ status: Int, location: String? = nil, body: String = "") -> (Data, HTTPURLResponse) {
        let headers = location.map { ["Location": $0] } ?? [:]
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
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
