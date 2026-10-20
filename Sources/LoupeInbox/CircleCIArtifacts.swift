import Foundation

/// Fetches CircleCI build artifacts, such as the visual review's report, with the user's CircleCI
/// token, for a web view to show under its own `loupe-artifact:` scheme. The page and every
/// relative file it loads go through here, so the token is only ever a request header sent to
/// CircleCI, never in the page, its URLs or anything stored. Only CircleCI's artifact hosts are
/// fetched.
public struct CircleCIArtifacts: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let scheme = "loupe-artifact"

    private let token: CircleCIToken
    private let transport: Transport

    public init(token: CircleCIToken, transport: @escaping Transport) {
        self.token = token
        self.transport = transport
    }

    /// Over `URLSession`, following redirects but sending the token on only to CircleCI's hosts.
    public static func live(token: CircleCIToken = CircleCIToken()) -> CircleCIArtifacts {
        let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
        return CircleCIArtifacts(token: token) { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    }

    /// What answered for an artifact.
    public enum Outcome: Sendable, Equatable {
        case loaded(Data, mimeType: String?, status: Int)
        /// No CircleCI token could be found to ask with.
        case needsToken
        /// CircleCI turned the token down.
        case refused(status: Int)
        case failed(String)
    }

    /// The `loupe-artifact:` URL serving the artifact at `url`; nil for any other host.
    public static func proxyURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", isArtifactHost(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        return components.url
    }

    /// The artifact a `loupe-artifact:` URL serves; nil for one naming any other host.
    public static func artifactURL(for proxyURL: URL) -> URL? {
        guard proxyURL.scheme?.lowercased() == scheme, isArtifactHost(proxyURL), var components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// Fetches what a `loupe-artifact:` URL serves, with the token as CircleCI asks for it.
    public func fetch(_ proxyURL: URL) async -> Outcome {
        guard let url = Self.artifactURL(for: proxyURL) else { return .failed("Only CircleCI's artifacts are fetched here") }
        guard let token = await token.value() else { return .needsToken }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: Self.tokenHeader)
        do {
            let (data, response) = try await transport(request)
            if [401, 403].contains(response.statusCode) {
                await self.token.forget()
                return .refused(status: response.statusCode)
            }
            return .loaded(data, mimeType: response.mimeType ?? response.value(forHTTPHeaderField: "Content-Type"), status: response.statusCode)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static let tokenHeader = "Circle-Token"

    static func isArtifactHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "circle-artifacts.com" || host.hasSuffix(".circle-artifacts.com")
    }

    static func isCircleCIHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return isArtifactHost(url) || host == "circleci.com" || host.hasSuffix(".circleci.com")
    }
}

/// The user's CircleCI API token, as the `circleci` CLI documents keeping it: `CIRCLE_TOKEN` in
/// the environment, else `token:` in the CLI's config file (`circleci setting set token`). Read
/// when first needed and kept in memory only; forgotten when CircleCI refuses it, so a new one
/// is read next time.
public actor CircleCIToken {
    private let read: @Sendable () -> String?
    private var cached: String?

    public init(read: @escaping @Sendable () -> String? = { CircleCIToken.fromCLISettings() }) {
        self.read = read
    }

    func value() -> String? {
        if let cached { return cached }
        cached = read()
        return cached
    }

    func forget() {
        cached = nil
    }

    /// `CIRCLE_TOKEN`, then the `token` setting in `$XDG_CONFIG_HOME/circleci/config.yml`
    /// (`~/.config` when that's unset).
    public static func fromCLISettings(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        if let token = environment["CIRCLE_TOKEN"]?.trimmingCharacters(in: .whitespaces), !token.isEmpty { return token }
        let configHome = environment["XDG_CONFIG_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? home.appending(path: ".config", directoryHint: .isDirectory)
        guard let settings = try? String(contentsOf: configHome.appending(path: "circleci/config.yml"), encoding: .utf8) else { return nil }
        return settings.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            guard let match = line.wholeMatch(of: /token:\s*["']?([^"'\s#]+)["']?\s*(?:#.*)?/) else { return nil }
            return String(match.output.1)
        }.first
    }
}

/// Follows a redirect, as CircleCI may send an artifact on elsewhere, with the token only on a
/// request to CircleCI.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, url.scheme?.lowercased() == "https" else { return nil }
        var request = request
        if CircleCIArtifacts.isCircleCIHost(url) {
            request.setValue(task.originalRequest?.value(forHTTPHeaderField: CircleCIArtifacts.tokenHeader), forHTTPHeaderField: CircleCIArtifacts.tokenHeader)
        } else {
            request.setValue(nil, forHTTPHeaderField: CircleCIArtifacts.tokenHeader)
        }
        return request
    }
}
