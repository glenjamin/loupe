import Foundation
import UniformTypeIdentifiers

/// CircleCI jobs' artifacts, such as the visual review's report, downloaded by the `circleci` CLI
/// into Loupe's cache and served from there to a web view under the `loupe-artifact:` scheme. The
/// CLI keeps its own sign-in, so Loupe never handles a CircleCI token. A job's artifacts never
/// change, so each job is downloaded once and kept until it has gone unopened for a while.
public struct CircleCIArtifacts: Sendable {
    public static let scheme = "loupe-artifact"

    /// Holds a directory of artifacts per job, named by the job's id.
    public let cache: URL
    private let environment: [String: String]

    /// `environment` is the CLI's, and where `LOUPE_CIRCLECI` names the CLI to run.
    public init(cache: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.cache = cache
        self.environment = environment
    }

    /// In `~/Library/Caches/Loupe/artifacts`, or `LOUPE_ARTIFACT_CACHE` when set, as for a
    /// snapshot run.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> CircleCIArtifacts {
        let cache = environment["LOUPE_ARTIFACT_CACHE"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.cachesDirectory.appending(components: "Loupe", "artifacts", directoryHint: .isDirectory)
        return CircleCIArtifacts(cache: cache, environment: environment)
    }

    /// A job left unopened this long is deleted.
    public static let keptFor: TimeInterval = 30 * 24 * 60 * 60

    /// How far a download has got: files written, of how many the CLI said it would fetch.
    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int?

        public init(done: Int, total: Int?) {
            self.done = done
            self.total = total
        }
    }

    /// Why an artifact can't be shown.
    public enum Failure: Error, Sendable, Equatable {
        case notAnArtifact(host: String)
        /// The `circleci` CLI couldn't be found or run.
        case cliMissing
        /// The CLI isn't signed in, or CircleCI turned its sign-in down; its own words.
        case refused(String)
        /// The CLI failed otherwise; its own words.
        case failed(String)
        /// The job's artifacts, downloaded, don't include the one asked for.
        case missing(path: String)
    }

    /// The `loupe-artifact:` URL to load the artifact at `url` from, once its job's artifacts are
    /// on disk: at once when they're kept from before, else after the CLI has downloaded them all,
    /// telling `progress` how far it has got. Either way the job counts as opened now. Throws a
    /// `Failure`, or `CancellationError` when cancelled, which stops the CLI.
    public func open(_ url: URL, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        guard let location = Location(url), let proxied = Self.proxyURL(for: url) else {
            throw Failure.notAnArtifact(host: url.host() ?? url.absoluteString)
        }
        let directory = directory(of: location.job)
        if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            progress(Progress(done: 0, total: nil))
            try await download(location, progress: progress)
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path(percentEncoded: false))
        guard file(at: location) != nil else { throw Failure.missing(path: location.path) }
        return proxied
    }

    /// What a `loupe-artifact:` URL serves from a downloaded job, with its MIME type; nil when the
    /// job isn't downloaded or hasn't the file. Nothing outside the job's directory is read.
    public func contents(of proxyURL: URL) -> (data: Data, mimeType: String)? {
        guard proxyURL.scheme?.lowercased() == Self.scheme, let location = Location(proxyURL), let file = file(at: location),
              let data = try? Data(contentsOf: file) else { return nil }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (data, type)
    }

    /// Deletes jobs not opened for `keptFor`, and downloads a crash left unfinished.
    public func prune(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let age = now.timeIntervalSince(modified)
            let name = entry.lastPathComponent
            if UUID(uuidString: name) != nil, age > Self.keptFor {
                try? fileManager.removeItem(at: entry)
            } else if name.hasPrefix(Self.partialPrefix), age > Self.partialKeptFor {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// The `loupe-artifact:` URL serving the artifact at `url`; nil for anything else.
    public static func proxyURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", Location(url) != nil, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        return components.url
    }

    /// The CircleCI job whose artifact `url` is, under either scheme; nil for anything else.
    public static func job(of url: URL) -> String? {
        Location(url)?.job
    }

    /// Runs the CLI into a directory beside the job's, which is renamed into place only once the
    /// CLI has finished, so an interrupted or failed download is never served.
    private func download(_ location: Location, progress: @escaping @Sendable (Progress) -> Void) async throws {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        prune()
        guard let executable = Self.executable(environment: environment) else { throw Failure.cliMissing }
        let partial = cache.appending(path: "\(Self.partialPrefix)\(location.job)-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: partial) }

        let run = CLIRun(executable: executable, arguments: ["artifact", location.job, "--output", partial.path(percentEncoded: false)], environment: environment.merging(Self.quietCLI) { _, quiet in quiet })
        let watcher = Task {
            var last: Progress?
            while !Task.isCancelled {
                let now = Progress(done: Self.fileCount(in: partial), total: run.announcedTotal)
                if now != last { progress(now) }
                last = now
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        let status = try await run.finish()
        guard status == 0 else {
            let message = run.errorMessage ?? "The circleci CLI stopped with status \(status)."
            // The CLI exits 3 when it has no sign-in or CircleCI rejects it.
            throw status == Self.authenticationStatus ? Failure.refused(message) : Failure.failed(message)
        }
        let done = Self.fileCount(in: partial)
        if let total = run.announcedTotal, done < total {
            throw Failure.failed("The circleci CLI downloaded \(done) of the job's \(total) artifacts.")
        }
        watcher.cancel()
        await watcher.value
        progress(Progress(done: done, total: run.announcedTotal))
        if !fileManager.fileExists(atPath: partial.path(percentEncoded: false)) {
            // A job with no artifacts at all leaves nothing behind.
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        }
        do {
            try fileManager.moveItem(at: partial, to: directory(of: location.job))
        } catch where fileManager.fileExists(atPath: directory(of: location.job).path(percentEncoded: false)) {
            // Another download of the job finished first; its copy is as good.
        } catch {
            throw Failure.failed("Couldn't keep the downloaded artifacts: \(error.localizedDescription)")
        }
    }

    private func directory(of job: String) -> URL {
        cache.appending(path: job, directoryHint: .isDirectory)
    }

    /// The file a location names in its downloaded job, if it's there, a regular file and inside
    /// the job's directory once links are resolved.
    private func file(at location: Location) -> URL? {
        let root = directory(of: location.job).resolvingSymlinksInPath()
        let file = root.appending(path: location.path).resolvingSymlinksInPath()
        guard file.pathComponents.count > root.pathComponents.count, file.pathComponents.starts(with: root.pathComponents),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return file
    }

    /// Homebrew's (Apple silicon, then Intel). `PATH` comes after, as an app launched from Finder
    /// has launchd's, without Homebrew's.
    static let preferredExecutables = ["/opt/homebrew/bin/circleci", "/usr/local/bin/circleci"]

    /// `LOUPE_CIRCLECI` outright when set, else the first of `candidates`, then of `PATH`'s, that
    /// can be run; nil when none can.
    static func executable(environment: [String: String], candidates: [String] = preferredExecutables) -> URL? {
        if let path = environment["LOUPE_CIRCLECI"], !path.isEmpty { return URL(filePath: path) }
        let onPath = (environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory).appending(path: "circleci") }
        return (candidates.map { URL(filePath: $0) } + onPath).first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// Keeps the CLI from prompting, colouring, animating or checking for updates.
    private static let quietCLI = [
        "CIRCLE_NO_INTERACTIVE": "1", "NO_COLOR": "1", "CIRCLE_SPINNER_DISABLED": "1",
        "CIRCLE_NO_UPDATE_CHECK": "1", "CIRCLE_NO_PAGER": "1",
    ]
    private static let authenticationStatus: Int32 = 3
    private static let partialPrefix = ".partial-"
    /// Long past any download still underway.
    private static let partialKeptFor: TimeInterval = 24 * 60 * 60

    private static func fileCount(in directory: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        return files.reduce(0) { count, entry in
            guard let url = entry as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return count }
            return count + 1
        }
    }
}

extension CircleCIArtifacts.Failure {
    public var title: String {
        switch self {
        case .notAnArtifact: "Not a CircleCI artifact"
        case .cliMissing: "Loupe needs the circleci CLI"
        case .refused: "The circleci CLI isn't signed in"
        case .failed: "Couldn't download the report"
        case .missing: "The report isn't among the job's artifacts"
        }
    }

    /// Markdown, for the commands to type in code.
    public var message: String {
        switch self {
        case let .notAnArtifact(host):
            "Loupe only opens reports kept as CircleCI artifacts; this one is at \(host)."
        case .cliMissing:
            "The report is a CircleCI artifact, which Loupe downloads with the `circleci` CLI. Install it with `brew install circleci`, sign in with `circleci auth login`, then try again."
        case let .refused(said):
            "\(said)\n\nSign the CLI in with `circleci auth login`, then try again."
        case let .failed(said):
            said
        case let .missing(path):
            "The job's artifacts have no `\(path)`. They may have expired."
        }
    }
}

/// Where an artifact is: CircleCI's job id and its path among the job's artifacts, from
/// `https://output.circle-artifacts.com/output/job/<job>/artifacts/<node>/<path>`, under either
/// scheme. The CLI downloads every node's artifacts into one directory by path, so the node is
/// left out.
private struct Location {
    let job: String
    let path: String

    init?(_ url: URL) {
        guard let host = url.host()?.lowercased(), host == "circle-artifacts.com" || host.hasSuffix(".circle-artifacts.com") else { return nil }
        let parts = Array(url.pathComponents.drop { $0 == "/" })
        guard parts.count > 5, parts[0] == "output", parts[1] == "job", let job = UUID(uuidString: parts[2]),
              parts[3] == "artifacts", parts[4].allSatisfy(\.isNumber) else { return nil }
        let path = parts.dropFirst(5)
        guard !path.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        self.job = job.uuidString.lowercased()
        self.path = path.joined(separator: "/")
    }
}

/// One run of the CLI: started by `finish`, which waits for it to exit; cancelling the waiting
/// task stops it. Its output is drained as it comes, so a chatty run never blocks on a full pipe.
private final class CLIRun: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorsPipe = Pipe()
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var isCancelled = false

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorsPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.append(handle.availableData, toErrors: false) }
        errorsPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.append(handle.availableData, toErrors: true) }
    }

    /// Runs the CLI to its end and gives its exit status.
    func finish() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                lock.lock()
                defer { lock.unlock() }
                guard !isCancelled else { return continuation.resume(throwing: CancellationError()) }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CircleCIArtifacts.Failure.cliMissing)
                }
            }
        } onCancel: {
            lock.withLock {
                isCancelled = true
                if process.isRunning { process.terminate() }
            }
        }
        for (pipe, isErrors) in [(outputPipe, false), (errorsPipe, true)] {
            pipe.fileHandleForReading.readabilityHandler = nil
            append(pipe.fileHandleForReading.readDataToEndOfFile(), toErrors: isErrors)
        }
        if lock.withLock({ isCancelled }) { throw CancellationError() }
        return process.terminationStatus
    }

    /// How many artifacts the CLI said, as it began, that it would download.
    var announcedTotal: Int? {
        let said = lock.withLock { String(decoding: errors + output, as: UTF8.self) }
        return said.firstMatch(of: /Downloading (\d+) artifact/).flatMap { Int($0.output.1) }
    }

    /// The first thing the CLI said on failing, without its "error:" label.
    var errorMessage: String? {
        let said = lock.withLock { [errors, output] in [errors, output].map { String(decoding: $0, as: UTF8.self) } }
        let line = said.lazy.flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("Downloading ") }
        guard let line else { return nil }
        let message = line.hasPrefix("error:") ? line.dropFirst("error:".count).trimmingCharacters(in: .whitespaces) : line
        return message.isEmpty ? nil : message
    }

    private func append(_ data: Data, toErrors: Bool) {
        guard !data.isEmpty else { return }
        lock.withLock {
            if toErrors { errors.append(data) } else { output.append(data) }
        }
    }
}
