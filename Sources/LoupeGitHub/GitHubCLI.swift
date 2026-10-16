import Foundation

public enum GitHubCLI {
    /// The token `gh` is signed in with. It's held only in memory for the request that needs it.
    @Sendable public static func authToken() async throws -> String {
        let process = Process()
        let found = executable(environment: ProcessInfo.processInfo.environment)
        if let executable = found {
            process.executableURL = executable
            process.arguments = ["auth", "token"]
        } else {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["gh", "auth", "token"]
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitHubError.token(error.localizedDescription))
            }
        }

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !output.isEmpty else {
            // `env` exits 127 when it can't find the command.
            if found == nil, process.terminationStatus == 127 {
                throw GitHubError.token(notFoundMessage)
            }
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubError.token(message.isEmpty ? "exit status \(process.terminationStatus)" : message)
        }
        return output
    }

    /// Homebrew's (Apple silicon, then Intel), then a system-wide install. `PATH` comes last, as
    /// an app launched from Finder or by a URL handler has launchd's, without Homebrew's.
    static let preferredExecutables = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    /// `LOUPE_GH` outright when set, else the first of `candidates` that can be run, else nil
    /// for `gh` to be looked for on `PATH`.
    static func executable(environment: [String: String], candidates: [String] = preferredExecutables) -> URL? {
        if let path = environment["LOUPE_GH"], !path.isEmpty { return URL(filePath: path) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }

    private static var notFoundMessage: String {
        let places = preferredExecutables.map { $0.dropLast("/gh".count) }
        return "gh isn't in \(places.joined(separator: ", ")) or on PATH; install it or set LOUPE_GH to its path"
    }
}
