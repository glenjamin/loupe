import Foundation

/// The token the `circleci` CLI is signed in with, printed by `command`: read when first needed
/// and kept in memory only, and read again once when CircleCI turns it down. Concurrent asks
/// share one run of the command.
actor CLIToken {
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

    /// Always `token`, as the fakes take.
    init(fixed token: String) {
        command = nil
        environment = [:]
        self.token = token
        hasRead = true
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
