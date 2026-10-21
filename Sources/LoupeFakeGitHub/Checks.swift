import Foundation
import os

/// A request the fakes weren't built to answer, or one not in the shape GitHub expects. The fakes
/// throw it rather than guess, so a test sees the request fail, and a run against the fixtures
/// can fail loudly instead of quietly reaching for the network.
public struct FakeGitHubMismatch: Error, CustomStringConvertible {
    public let description: String

    /// Every mismatch so far in this process, oldest first.
    public static var recorded: [String] { log.withLock { $0 } }

    fileprivate static let log = OSAllocatedUnfairLock<[String]>(initialState: [])
}

/// The value, or a thrown `FakeGitHubMismatch` saying what was missing.
func require<T>(_ value: T?, _ message: @autoclosure () -> String = "", fileID: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw mismatch("expected a value", message(), fileID, line) }
    return value
}

/// Throws a `FakeGitHubMismatch` unless `condition` holds.
func require(_ condition: Bool, _ message: @autoclosure () -> String = "", fileID: String = #fileID, line: Int = #line) throws {
    guard condition else { throw mismatch("expectation failed", message(), fileID, line) }
}

/// A check on a request's shape, as GitHub would refuse a malformed one.
func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", fileID: String = #fileID, line: Int = #line) throws {
    try require(condition, message(), fileID: fileID, line: line)
}

/// Records and prints a mismatch, for the caller to throw.
func mismatch(_ kind: String, _ message: String, _ fileID: String = #fileID, _ line: Int = #line) -> FakeGitHubMismatch {
    let description = "fake GitHub: \(message.isEmpty ? kind : message) (\(fileID):\(line))"
    FakeGitHubMismatch.log.withLock { $0.append(description) }
    FileHandle.standardError.write(Data("\(description)\n".utf8))
    return FakeGitHubMismatch(description: description)
}
