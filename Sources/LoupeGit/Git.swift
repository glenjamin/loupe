import Foundation

/// Runs git against a checkout. Only read-only commands belong here: the checkouts are the
/// user's working copies.
enum Git {
    static func originURL(of directory: URL) async throws -> String {
        try await run(["remote", "get-url", "origin"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// git's stdout. Runs on a background queue, as it blocks until git exits.
    static func run(_ arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(arguments, in: directory) })
            }
        }
    }

    private static func runBlocking(_ arguments: [String], in directory: URL) throws -> String {
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
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(arguments: arguments, status: process.terminationStatus, message: String(decoding: errorOutput, as: UTF8.self))
        }
        return String(decoding: output, as: UTF8.self)
    }
}

struct GitError: Error, LocalizedError {
    let arguments: [String]
    let status: Int32
    let message: String

    var errorDescription: String? {
        "git \(arguments.joined(separator: " ")) exited with \(status): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
