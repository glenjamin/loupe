import Foundation
import os

/// Runs git against a checkout. The checkouts are the user's working copies, so diffing never
/// touches branches, the index or the working tree; the only ref it writes is Loupe's own
/// `refs/loupe/` namespace, and objects it makes itself go to an object directory of Loupe's
/// own. Only `CheckoutSwitcher`, when asked, switches branches.
enum Git {
    /// The git Loupe runs: `LOUPE_GIT` if set, else Homebrew's (Apple silicon, then Intel), else
    /// Apple's. Homebrew's is newer and is the one the shell finds, so diffs match the terminal's.
    /// `PATH` isn't consulted, as an app launched from Finder doesn't have the shell's.
    static let executable: URL = {
        let url = executable(environment: ProcessInfo.processInfo.environment)
        logger.info("Using \(url.path(percentEncoded: false), privacy: .public): \(version(of: url), privacy: .public)")
        return url
    }()

    static let preferredExecutables = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]

    /// `LOUPE_GIT` outright when set, else the first of `candidates` that can be run.
    static func executable(environment: [String: String], candidates: [String] = preferredExecutables) -> URL {
        if let path = environment["LOUPE_GIT"], !path.isEmpty { return URL(filePath: path) }
        return URL(filePath: candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git")
    }

    /// The checkout's remotes in config order, with their URLs as configured rather than as any
    /// `insteadOf` rewrites them, since those name the repo. Empty when there are none.
    static func remotes(of directory: URL) async -> [Remote] {
        guard let config = try? await run(["config", "--get-regexp", #"^remote\..*\.url$"#], in: directory) else { return [] }
        return config.split(separator: "\n").compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let name = line[..<space].dropFirst("remote.".count).dropLast(".url".count)
            return Remote(name: String(name), url: String(line[line.index(after: space)...]))
        }
    }

    struct Remote: Equatable {
        let name: String
        let url: String
    }

    /// git's stdout, given `input` on stdin and `environment` added to its own. Runs on a
    /// thread of its own, as it blocks until git exits, and kills git if it outlasts `timeout`.
    /// `statuses` are the exit statuses that aren't failures, for commands such as `merge-tree`
    /// that answer with their status as well as their output.
    static func run(_ arguments: [String], in directory: URL, input: Data? = nil, environment: [String: String] = [:], timeout: Duration = .seconds(30), succeedingOn statuses: Set<Int32> = [0]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            onOwnThread {
                continuation.resume(with: Result {
                    try runBlocking(arguments, in: directory, input: input, environment: environment, timeout: timeout, succeedingOn: statuses) { String(decoding: $0.readDataToEndOfFile(), as: UTF8.self) }
                })
            }
        }
    }

    /// git's stdout as bytes, for output that isn't text, such as an image's blob.
    static func data(_ arguments: [String], in directory: URL, environment: [String: String] = [:], timeout: Duration = .seconds(30)) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            onOwnThread {
                continuation.resume(with: Result { try runBlocking(arguments, in: directory, input: nil, environment: environment, timeout: timeout) { $0.readDataToEndOfFile() } })
            }
        }
    }

    /// Runs git for long work such as a clone, handing each piece of what it writes to stderr,
    /// where it reports progress, to `progress` as it comes. Cancelling the task kills git and
    /// throws `CancellationError` once it has exited.
    static func runReportingProgress(_ arguments: [String], in directory: URL, timeout: Duration, progress: @escaping @Sendable (String) -> Void) async throws {
        let watchdog = Watchdog()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                onOwnThread {
                    continuation.resume(with: Result {
                        try runBlocking(arguments, in: directory, input: nil, timeout: timeout, watchdog: watchdog, onError: { progress(String(decoding: $0, as: UTF8.self)) }) { _ = $0.readDataToEndOfFile() }
                    })
                }
            }
        } onCancel: {
            watchdog.fire(.cancelled)
        }
    }

    /// Whether git exits successfully, for commands that answer a yes/no question.
    static func succeeds(_ arguments: [String], in directory: URL) async -> Bool {
        (try? await run(arguments, in: directory)) != nil
    }

    /// The text of each object named, such as `<commit>:<path>`, up to and including the line
    /// its `lines` asks for, all read by one `git cat-file --batch`. Only those lines are kept, so
    /// a large file costs only its passage through the pipe. Nil for a name that isn't a blob, or
    /// that has a newline, which batch input can't carry.
    static func firstLines(of objects: [(name: String, lines: Int)], in directory: URL, environment: [String: String] = [:], timeout: Duration = .seconds(30)) async throws -> [String?] {
        let sendable = objects.filter { !$0.name.contains("\n") }
        guard !sendable.isEmpty else { return objects.map { _ in nil } }
        let input = Data(sendable.map { $0.name + "\n" }.joined().utf8)
        let lines = sendable.map(\.lines)
        let heads = try await withCheckedThrowingContinuation { continuation in
            onOwnThread {
                continuation.resume(with: Result {
                    try runBlocking(["cat-file", "--batch"], in: directory, input: input, environment: environment, timeout: timeout) { output in
                        var reader = BatchReader(lines: lines)
                        while let chunk = try output.read(upToCount: 1 << 16), !chunk.isEmpty { reader.consume(chunk) }
                        return reader.heads
                    }
                })
            }
        }
        var answers = heads.makeIterator()
        return objects.map { $0.name.contains("\n") ? nil : answers.next() ?? nil }
    }

    /// Runs git, handing its stdout to `read` as it comes, and returns what that makes of it.
    /// Stops early when `watchdog` fires, and hands stderr to `onError` as it comes if given.
    private static func runBlocking<Output>(_ arguments: [String], in directory: URL, input: Data?, environment extra: [String: String] = [:], timeout: Duration, succeedingOn statuses: Set<Int32> = [0], watchdog: Watchdog = Watchdog(), onError: (@Sendable (Data) -> Void)? = nil, read: (FileHandle) throws -> Output) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", directory.path(percentEncoded: false)] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment.merge(extra) { $1 }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        try process.run()
        if let stdin, let input {
            // Written alongside the reads below, so a large input can't deadlock against git's output.
            onOwnThread {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        watchdog.watch(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { watchdog.fire(.timedOut) }
        // Both pipes are drained at once, so git never blocks writing to a full one.
        let errorOutput = Drain(stderr.fileHandleForReading, onChunk: onError)
        let output = Result { try read(stdout.fileHandleForReading) }
        if case .failure(let error) = output {
            // Git would otherwise block on a pipe nobody reads.
            process.terminate()
            process.waitUntilExit()
            watchdog.disarm()
            throw error
        }
        process.waitUntilExit()
        watchdog.disarm()

        let message = String(decoding: errorOutput.wait(), as: UTF8.self)
        switch watchdog.reason {
        case .timedOut?: throw GitError(arguments: arguments, status: nil, message: "timed out after \(timeout). \(message)")
        case .cancelled?: throw CancellationError()
        case nil: break
        }
        guard statuses.contains(process.terminationStatus) else {
            throw GitError(arguments: arguments, status: process.terminationStatus, message: message)
        }
        return try output.get()
    }
}

public struct GitError: Error, LocalizedError {
    public let arguments: [String]
    /// Nil when git was killed for taking too long.
    public let status: Int32?
    /// What git wrote to stderr.
    public let message: String

    public var errorDescription: String? {
        let outcome = status.map { "exited with \($0)" } ?? "didn't finish"
        return "git \(arguments.joined(separator: " ")) \(outcome): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Kills a process that runs past its deadline or whose task is cancelled, remembering why.
/// It can fire before the process starts, which is then killed as soon as it's watched.
private final class Watchdog: @unchecked Sendable {
    enum Reason {
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var process: Process?
    private var armed = true
    private var fired: Reason?

    var reason: Reason? { lock.withLock { fired } }

    func watch(_ process: Process) {
        lock.withLock {
            self.process = process
            if fired != nil, process.isRunning { process.terminate() }
        }
    }

    func fire(_ reason: Reason) {
        lock.withLock {
            guard armed, fired == nil else { return }
            if let process {
                guard process.isRunning else { return }
                process.terminate()
            }
            fired = reason
        }
    }

    func disarm() {
        lock.withLock { armed = false }
    }
}

/// Parses `git cat-file --batch` output as it arrives: for each object asked for, a header line,
/// `<oid> <type> <size>` or `<name> missing`, then for one found its content and a newline. Keeps
/// each blob's text up to its wanted number of lines and drops the rest as it passes.
private struct BatchReader {
    private(set) var heads: [String?] = []
    private let lines: [Int]
    private var pending = Data()
    /// The current object's content: how much is still to come, and the part being kept.
    private var body: (remaining: Int, kept: Data, newlines: Int, isBlob: Bool)?

    init(lines: [Int]) {
        self.lines = lines
    }

    mutating func consume(_ chunk: Data) {
        pending.append(chunk)
        while true {
            if var current = body {
                let part = pending.prefix(current.remaining)
                if current.isBlob {
                    // Kept through the wanted line's newline, and no further.
                    var end = part.startIndex
                    while end < part.endIndex, current.newlines < wanted {
                        if part[end] == UInt8(ascii: "\n") { current.newlines += 1 }
                        end += 1
                    }
                    current.kept.append(part[part.startIndex..<end])
                }
                current.remaining -= part.count
                pending.removeFirst(part.count)
                // The content is followed by a newline of its own.
                guard current.remaining == 0, !pending.isEmpty else {
                    body = current
                    return
                }
                pending.removeFirst()
                heads.append(current.isBlob ? String(decoding: current.kept, as: UTF8.self) : nil)
                body = nil
            } else {
                guard let newline = pending.firstIndex(of: UInt8(ascii: "\n")) else { return }
                let header = pending[pending.startIndex..<newline].split(separator: UInt8(ascii: " "))
                pending.removeSubrange(pending.startIndex...newline)
                if header.count == 3, let size = Int(String(decoding: header[2], as: UTF8.self)) {
                    body = (size, Data(), 0, header[1].elementsEqual("blob".utf8))
                } else {
                    heads.append(nil)
                }
            }
        }
    }

    /// How many lines of the current object to keep.
    private var wanted: Int { heads.count < lines.count ? lines[heads.count] : 0 }
}

/// Reads a pipe to its end on another thread, handing each piece to `onChunk` as it comes if
/// given.
private final class Drain: @unchecked Sendable {
    private let group = DispatchGroup()
    private var data = Data()

    init(_ handle: FileHandle, onChunk: (@Sendable (Data) -> Void)? = nil) {
        group.enter()
        onOwnThread {
            if let onChunk {
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    self.data.append(chunk)
                    onChunk(chunk)
                }
            } else {
                self.data = handle.readDataToEndOfFile()
            }
            self.group.leave()
        }
    }

    func wait() -> Data {
        group.wait()
        return data
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

private let logger = Logger(subsystem: "com.glenmailer.Loupe", category: "git")

/// What `git --version` says, for the log; run directly, as `Git.run` needs the executable chosen.
private func version(of executable: URL) -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--version"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "can't run: \(error.localizedDescription)" }
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Runs blocking work on a thread of its own rather than GCD's global pool. That pool's threads
/// are capped, and a git run blocks waiting on its stdin writer, its stderr drain and its
/// watchdog, so enough runs at once holding every pool thread would leave those never run.
private func onOwnThread(_ work: @escaping @Sendable () -> Void) {
    let thread = Thread(block: work)
    thread.qualityOfService = .userInitiated
    thread.start()
}
