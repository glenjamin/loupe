import Foundation

/// Runs git against a checkout. The checkouts are the user's working copies, so nothing here
/// touches branches, the index or the working tree; the only ref written is Loupe's own
/// `refs/loupe/` namespace.
enum Git {
    static func originURL(of directory: URL) async throws -> String {
        try await run(["remote", "get-url", "origin"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// git's stdout, given `input` on stdin. Runs on a background queue, as it blocks until git
    /// exits, and kills git if it outlasts `timeout`.
    static func run(_ arguments: [String], in directory: URL, input: Data? = nil, timeout: Duration = .seconds(30)) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(arguments, in: directory, input: input, timeout: timeout) })
            }
        }
    }

    /// Whether git exits successfully, for commands that answer a yes/no question.
    static func succeeds(_ arguments: [String], in directory: URL) async -> Bool {
        (try? await run(arguments, in: directory)) != nil
    }

    private static func runBlocking(_ arguments: [String], in directory: URL, input: Data?, timeout: Duration) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path(percentEncoded: false)] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
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
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        let watchdog = Watchdog(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { watchdog.fire() }
        // Both pipes are drained at once, so git never blocks writing to a full one.
        let errorOutput = Drain(stderr.fileHandleForReading)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.disarm()

        let message = String(decoding: errorOutput.wait(), as: UTF8.self)
        if watchdog.fired {
            throw GitError(arguments: arguments, status: nil, message: "timed out after \(timeout). \(message)")
        }
        guard process.terminationStatus == 0 else {
            throw GitError(arguments: arguments, status: process.terminationStatus, message: message)
        }
        return String(decoding: output, as: UTF8.self)
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

/// Kills a process that runs past its deadline, remembering that it did.
private final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var armed = true
    private var didFire = false

    init(_ process: Process) {
        self.process = process
    }

    var fired: Bool { lock.withLock { didFire } }

    func fire() {
        lock.withLock {
            guard armed, process.isRunning else { return }
            didFire = true
            process.terminate()
        }
    }

    func disarm() {
        lock.withLock { armed = false }
    }
}

/// Reads a pipe to its end on another thread.
private final class Drain: @unchecked Sendable {
    private let group = DispatchGroup()
    private var data = Data()

    init(_ handle: FileHandle) {
        group.enter()
        DispatchQueue.global().async {
            self.data = handle.readDataToEndOfFile()
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
