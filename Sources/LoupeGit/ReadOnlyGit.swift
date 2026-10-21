import Foundation
import os

/// Keeps git to reading the user's checkouts, for snapshot runs that click through the real app:
/// no clone, branch switch, merge or other change to their refs, index or working tree. What
/// diffing needs still runs: fetching into Loupe's `refs/loupe/`, and writing objects or indexes
/// that are Loupe's own. A refused command throws before git is started, and is kept in
/// `refused`.
public enum ReadOnlyGit {
    private static let state = OSAllocatedUnfairLock(initialState: (isOn: false, refused: [String]()))

    /// Refuses writes from now on, everywhere in the process.
    public static func enable() {
        state.withLock { $0.isOn = true }
    }

    /// Refuses writes within a task and its children only, as tests that share the process do.
    @TaskLocal public static var isOnHere = false

    /// Each command refused so far, oldest first, as `git <arguments>`.
    public static var refused: [String] { state.withLock { $0.refused } }

    static func check(_ arguments: [String], environment: [String: String]) throws {
        guard isOnHere || state.withLock({ $0.isOn }), !isReading(arguments, environment: environment) else { return }
        let command = "git " + arguments.joined(separator: " ")
        state.withLock { $0.refused.append(command) }
        FileHandle.standardError.write(Data("blocked in snapshot run: \(command)\n".utf8))
        throw GitError(arguments: arguments, status: nil, message: "blocked in snapshot run")
    }
}

/// Whether git run with `arguments` leaves the checkout's refs, index and working tree as they
/// were, apart from Loupe's own refs. Anything not known to be safe counts as a write.
private func isReading(_ arguments: [String], environment: [String: String]) -> Bool {
    // `-c name=value` pairs come before the command.
    var rest = arguments[...]
    while rest.first == "-c" { rest = rest.dropFirst(2) }
    guard let command = rest.first else { return true }
    let options = rest.dropFirst()
    switch command {
    case "cat-file", "check-attr", "diff", "diff-tree", "for-each-ref", "log", "ls-files", "ls-remote", "ls-tree",
         "merge-base", "rev-list", "rev-parse", "show", "show-ref", "status", "blame", "version":
        return true
    case "hash-object":
        return !options.contains("-w") || environment["GIT_OBJECT_DIRECTORY"] != nil
    case "merge-tree", "write-tree":
        // Objects go to Loupe's own directory, or nowhere.
        return environment["GIT_OBJECT_DIRECTORY"] != nil || command == "write-tree" && environment["GIT_INDEX_FILE"] != nil
    case "read-tree", "update-index":
        return environment["GIT_INDEX_FILE"] != nil
    case "config":
        return options.contains { ["--get", "--get-all", "--get-regexp", "--list", "-l"].contains($0) }
    case "fetch":
        // A refspec naming where it goes must go under Loupe's refs; one that doesn't only
        // updates the remote's tracking branch, as any fetch would.
        return options.filter { !$0.hasPrefix("-") }.allSatisfy { spec in
            guard let colon = spec.lastIndex(of: ":") else { return true }
            return spec[spec.index(after: colon)...].hasPrefix("refs/loupe/")
        }
    default:
        return false
    }
}
