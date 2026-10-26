import Foundation

/// Reads the signed-in user's participating notifications, GitHub's cheap signal that a PR they
/// care about has changed: a poll with nothing new is a 304, which costs no rate limit. It only
/// reads, so nothing is marked as read.
public struct GitHubNotifications: Sendable {
    public typealias TokenProvider = GitHubClient.TokenProvider

    private let token: TokenProvider
    private let transport: any HTTPTransport
    private let endpoint = URL(string: "https://api.github.com/notifications?participating=true")!

    public init(token: @escaping TokenProvider = GitHubCLI.authToken, transport: any HTTPTransport = URLSession.shared) {
        self.token = token
        self.transport = transport
    }

    /// The PRs the newest notifications are about, unless nothing has changed since the poll
    /// that returned `lastModified`. Throws `GitHubError.http` when GitHub refuses, such as a 403
    /// for a token that can't read notifications.
    public func poll(ifModifiedSince lastModified: String?) async throws -> NotificationsPoll {
        var request = URLRequest(url: endpoint)
        // A cached response would hide the 304 that says nothing changed.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let (body, response) = try await transport.send(request)
        // GitHub asks for no more than one poll per this many seconds, 304s included.
        let interval = response.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(Int.init).map(Duration.seconds) ?? Self.defaultInterval
        switch response.statusCode {
        case 304:
            return NotificationsPoll(outcome: .unchanged, interval: interval)
        case 200:
            let threads = try JSONDecoder().decode([NotificationThread].self, from: body)
            let pullRequests = threads.compactMap { $0.subject.type == "PullRequest" ? $0.subject.url.flatMap(PullRequestReference.init) : nil }
            return NotificationsPoll(outcome: .changed(pullRequests, lastModified: response.value(forHTTPHeaderField: "Last-Modified")), interval: interval)
        default:
            throw GitHubError.http(status: response.statusCode, body: body)
        }
    }

    /// GitHub's documented interval, for a response that doesn't say.
    static let defaultInterval = Duration.seconds(60)
}

/// What a notifications poll found, and how long to leave it before the next.
public struct NotificationsPoll: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case unchanged
        /// Newest first. `lastModified` is to be passed to the next poll.
        case changed([PullRequestReference], lastModified: String?)
    }

    public let outcome: Outcome
    public let interval: Duration
}

/// A PR named by repo and number, as REST names it.
public struct PullRequestReference: Sendable, Hashable {
    /// `owner/name`.
    public let repository: String
    public let number: Int

    public init(repository: String, number: Int) {
        self.repository = repository
        self.number = number
    }

    /// From an API URL of the form `https://api.github.com/repos/<owner>/<name>/pulls/<number>`.
    init?(_ url: URL) {
        let parts = url.pathComponents
        guard parts.count == 6, parts[1] == "repos", parts[4] == "pulls", let number = Int(parts[5]) else { return nil }
        repository = "\(parts[2])/\(parts[3])"
        self.number = number
    }
}

private struct NotificationThread: Decodable {
    let subject: Subject

    struct Subject: Decodable {
        let type: String
        /// Null for some subject types, such as check suites.
        let url: URL?
    }
}

