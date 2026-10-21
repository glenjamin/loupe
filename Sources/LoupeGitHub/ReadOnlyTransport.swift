import Foundation
import os

/// Lets only reads through to GitHub: GraphQL queries, REST `GET`s and `HEAD`s, and rendering
/// markdown, a `POST` that changes nothing. Every other request, GraphQL mutations and REST
/// writes alike, is refused before it leaves the process and kept in `blocked`, so a snapshot
/// run that clicks Merge, a reviewer or Submit can't change anything on GitHub.
public final class ReadOnlyTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let refused = OSAllocatedUnfairLock<[String]>(initialState: [])

    public init(wrapping base: any HTTPTransport = URLSession.shared) {
        self.base = base
    }

    /// Each write refused so far, oldest first, named as `write(in:)` names it.
    public var blocked: [String] { refused.withLock { $0 } }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let write = Self.write(in: request) {
            refused.withLock { $0.append(write) }
            FileHandle.standardError.write(Data("blocked in snapshot run: \(write)\n".utf8))
            throw BlockedWrite(request: write)
        }
        return try await base.send(request)
    }

    /// What `request` would change, nil if it only reads: a GraphQL mutation by its first
    /// field, such as `requestReviews`, or a REST write by its method and path. A GraphQL body
    /// that can't be read counts as a write, so nothing gets through by looking unusual.
    public static func write(in request: URLRequest) -> String? {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path() ?? ""
        if path == "/graphql" {
            guard let body = request.httpBody,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
            else { return "unreadable GraphQL request" }
            return mutation(in: envelope.query)
        }
        if ["GET", "HEAD"].contains(method) || method == "POST" && path == "/markdown" { return nil }
        return "\(method) \(path)"
    }

    private struct Envelope: Decodable {
        let query: String
    }
}

/// A request a `ReadOnlyTransport` refused to send.
public struct BlockedWrite: Error, LocalizedError, Equatable {
    public let request: String

    public var errorDescription: String? { "Blocked in snapshot run: \(request)" }
}

/// The first field a GraphQL document's mutation (or subscription) asks for, or nil when the
/// document is only queries. Anything that isn't plainly a query counts as a mutation.
private func mutation(in document: String) -> String? {
    let words = document.split { !($0.isLetter || $0.isNumber || $0 == "_") }
    let first = document.drop { $0.isWhitespace }
    let isQuery = (first.hasPrefix("query") || first.hasPrefix("{")) && !words.contains { $0 == "mutation" || $0 == "subscription" }
    guard !isQuery else { return nil }
    guard let keyword = document.range(of: "mutation") ?? document.range(of: "subscription"),
          let brace = document[keyword.upperBound...].firstIndex(of: "{")
    else { return "unnamed mutation" }
    // Skipping the operation's variables, the first word inside its braces is the field.
    let field = document[document.index(after: brace)...].split { !($0.isLetter || $0.isNumber || $0 == "_") }.first
    return field.map(String.init) ?? "unnamed mutation"
}
