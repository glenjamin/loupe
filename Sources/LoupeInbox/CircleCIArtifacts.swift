import Foundation
import UniformTypeIdentifiers

/// CircleCI jobs' artifacts, such as the visual review's report, kept in Loupe's cache and served
/// from there to a web view under the `loupe-artifact:` scheme. With the token the `circleci` CLI
/// is signed in with, read by a command, each file is fetched from CircleCI as the page asks for
/// it; without one, the CLI downloads the whole job with its own sign-in. The token is held in
/// memory only and sent only to CircleCI. A job's artifacts never change, so each file is fetched
/// once and kept until its job has gone unopened for a while.
public struct CircleCIArtifacts: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let scheme = "loupe-artifact"

    /// Holds a directory of artifacts per job, named by the job's id.
    public let cache: URL
    private let environment: [String: String]
    private let token: CLIToken
    private let transport: Transport

    /// `environment` is the CLI's and the token command's, and where `LOUPE_CIRCLECI` names the
    /// CLI to run and `LOUPE_CIRCLECI_TOKEN_COMMAND` the command printing its token, else
    /// `tokenCommand`. Without either, the CLI downloads every job. `transport` makes one request,
    /// returning a redirect rather than following it.
    public init(cache: URL, environment: [String: String] = ProcessInfo.processInfo.environment, tokenCommand: URL? = nil, transport: @escaping Transport = CircleCIArtifacts.urlSession) {
        self.cache = cache
        self.environment = environment
        let command = environment["LOUPE_CIRCLECI_TOKEN_COMMAND"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) } ?? tokenCommand
        token = CLIToken(command: command, environment: environment)
        self.transport = transport
    }

    /// In `~/Library/Caches/Loupe/artifacts`, or `LOUPE_ARTIFACT_CACHE` when set, as for a
    /// snapshot run, with the token read by the app's `circleci-token` script.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> CircleCIArtifacts {
        let cache = environment["LOUPE_ARTIFACT_CACHE"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.cachesDirectory.appending(components: "Loupe", "artifacts", directoryHint: .isDirectory)
        return CircleCIArtifacts(cache: cache, environment: environment, tokenCommand: tokenScript)
    }

    /// Over an ephemeral `URLSession` with no cache of its own, as files are kept on disk here.
    public static let urlSession: Transport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RedirectsReturned(), delegateQueue: nil)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    }()

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

    /// What answers a `loupe-artifact:` URL.
    public struct Served: Sendable, Equatable {
        public var status: Int
        public var data: Data
        public var mimeType: String

        public static let notFound = Served(status: 404, data: Data("Not found".utf8), mimeType: "text/plain")
    }

    /// The `loupe-artifact:` URL to load the artifact at `url` from, once it's on disk: at once
    /// when it's kept from before; else fetched alone with the CLI's token, read afresh; else,
    /// when there's no token, after the CLI has downloaded the whole job, telling `progress` how
    /// far it has got. Either way the job counts as opened now. Throws a `Failure`, or
    /// `CancellationError` when cancelled, which stops the CLI.
    public func open(_ url: URL, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        guard let location = Location(url), let proxied = Self.proxyURL(for: url) else {
            throw Failure.notAnArtifact(host: url.host() ?? url.absoluteString)
        }
        if file(at: location) == nil {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            prune()
            if let token = await token.refresh() {
                try await fetchReport(location, token: token)
            } else {
                progress(Progress(done: 0, total: nil))
                try await download(location, progress: progress)
            }
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory(of: location.job).path(percentEncoded: false))
        guard file(at: location) != nil else { throw Failure.missing(path: location.path) }
        return proxied
    }

    /// What a `loupe-artifact:` URL serves: the file kept from its job, else fetched now with the
    /// CLI's token and kept, else 404. Nothing outside the job's directory is read or written.
    public func serve(_ proxyURL: URL) async -> Served {
        guard proxyURL.scheme?.lowercased() == Self.scheme, let location = Location(proxyURL) else { return .notFound }
        if let file = file(at: location), let data = try? Data(contentsOf: file) {
            return Served(status: 200, data: data, mimeType: Self.mimeType(of: file) ?? "application/octet-stream")
        }
        guard let token = await token.current() else { return .notFound }
        do {
            return try await fetch(location, token: token)
        } catch {
            return Served(status: 502, data: Data(error.localizedDescription.utf8), mimeType: "text/plain")
        }
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
            let directory = directory(of: location.job)
            if fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
                // Files fetched one by one while signed in; the whole job supersedes them.
                _ = try fileManager.replaceItemAt(directory, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: directory)
            }
        } catch {
            throw Failure.failed("Couldn't keep the downloaded artifacts: \(error.localizedDescription)")
        }
    }

    /// Fetches the report on its own, so a refusal or its absence is said before the page loads.
    private func fetchReport(_ location: Location, token: String) async throws {
        let served: Served
        do {
            served = try await fetch(location, token: token)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.failed("Couldn't fetch the report from CircleCI: \(error.localizedDescription)")
        }
        switch served.status {
        case 200, 404: break
        case 401, 403: throw Failure.refused("CircleCI turned down the token the circleci CLI is signed in with.")
        default: throw Failure.failed("CircleCI answered the report with \(served.status) \(HTTPURLResponse.localizedString(forStatusCode: served.status)).")
        }
    }

    /// Fetches an artifact from CircleCI with `token`, reading the token again once if it's
    /// turned down, and keeps it in its job's directory when found.
    private func fetch(_ location: Location, token: String) async throws -> Served {
        var (data, response) = try await get(location.url, token: token)
        if Self.refusals.contains(response.statusCode), let renewed = await self.token.renewed(after: token), renewed != token {
            (data, response) = try await get(location.url, token: renewed)
        }
        let mimeType = Self.mimeType(of: location.url) ?? response.mimeType ?? "application/octet-stream"
        if response.statusCode == 200 { keep(data, at: location) }
        return Served(status: response.statusCode, data: data, mimeType: mimeType)
    }

    /// GETs `url`, following redirects over https, with the token sent only to CircleCI's hosts.
    private func get(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var url = url
        for _ in 0...Self.redirectLimit {
            var request = URLRequest(url: url)
            if Self.isCircleCIHost(url) { request.setValue(token, forHTTPHeaderField: Self.tokenHeader) }
            let (data, response) = try await transport(request)
            guard (300...399).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL, next.scheme?.lowercased() == "https" else {
                return (data, response)
            }
            url = next
        }
        throw URLError(.httpTooManyRedirects)
    }

    /// Writes a fetched file into its job's directory, never through a link out of it. Failing to
    /// keep it only means fetching it again.
    private func keep(_ data: Data, at location: Location) {
        let root = directory(of: location.job)
        let file = root.appending(path: location.path)
        let folder = file.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              folder.resolvingSymlinksInPath().pathComponents.starts(with: root.resolvingSymlinksInPath().pathComponents) else { return }
        try? data.write(to: file, options: .atomic)
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
    /// The script reading the token the CLI keeps: in the app's resources, else in the checkout a
    /// bare build runs from.
    static var tokenScript: URL? {
        if let bundled = Bundle.main.url(forResource: "circleci-token", withExtension: nil) { return bundled }
        let checkout = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = checkout.appending(path: "Scripts/circleci-token")
        return FileManager.default.isExecutableFile(atPath: script.path(percentEncoded: false)) ? script : nil
    }

    static let tokenHeader = "Circle-Token"
    private static let refusals: Set<Int> = [401, 403]
    private static let redirectLimit = 5

    static func isCircleCIHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return ["circle-artifacts.com", "circleci.com"].contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func mimeType(of url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

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
/// left out of where it's kept.
private struct Location {
    let job: String
    let path: String
    /// Where CircleCI serves it.
    let url: URL

    init?(_ url: URL) {
        guard let host = url.host()?.lowercased(), host == "circle-artifacts.com" || host.hasSuffix(".circle-artifacts.com") else { return nil }
        let parts = Array(url.pathComponents.drop { $0 == "/" })
        guard parts.count > 5, parts[0] == "output", parts[1] == "job", let job = UUID(uuidString: parts[2]),
              parts[3] == "artifacts", parts[4].allSatisfy(\.isNumber) else { return nil }
        let path = parts.dropFirst(5)
        guard !path.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.scheme = "https"
        components.fragment = nil
        guard let https = components.url else { return nil }
        self.job = job.uuidString.lowercased()
        self.path = path.joined(separator: "/")
        self.url = https
    }
}

/// The token the `circleci` CLI is signed in with, printed by `command`: read when a report is
/// opened and kept in memory only, and read again once when CircleCI turns it down. Concurrent
/// asks share one run of the command.
private actor CLIToken {
    private let command: URL?
    private let environment: [String: String]
    private var token: String?
    private var hasRead = false
    private var reading: Task<String?, Never>?
    /// The token last turned down and read again for, so it's read again only once.
    private var renewedFrom: String?

    init(command: URL?, environment: [String: String]) {
        self.command = command
        self.environment = environment
    }

    /// Reads the token afresh; nil when there's no command or it printed none.
    func refresh() async -> String? {
        renewedFrom = nil
        return await read()
    }

    /// The token read last, read now if it never has been.
    func current() async -> String? {
        if let reading { return await reading.value }
        return hasRead ? token : await read()
    }

    /// A token to try after CircleCI turned `refused` down: one read since, or read again now,
    /// but only once for the same token.
    func renewed(after refused: String) async -> String? {
        if let reading { return await reading.value }
        guard token == refused else { return token }
        guard renewedFrom != refused else { return nil }
        renewedFrom = refused
        return await read()
    }

    private func read() async -> String? {
        if let reading { return await reading.value }
        let task = Task { [command, environment] () -> String? in
            guard let command else { return nil }
            return await Self.run(command, environment: environment)
        }
        reading = task
        let read = await task.value
        reading = nil
        token = read
        hasRead = true
        return read
    }

    /// The command's one line of output, when it exits cleanly; what it says otherwise is let go.
    private static func run(_ command: URL, environment: [String: String]) async -> String? {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = command
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let token = String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !token.isEmpty, !token.contains(where: \.isNewline) else { return nil }
            return token
        }.value
    }
}

/// Hands each redirect back to `CircleCIArtifacts`, which decides where the token may go.
private final class RedirectsReturned: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
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
