import Foundation
import LoupeModel

/// Reads Terraform Cloud runs' plans from its API, with the token `terraform login` stored. Only
/// GETs are sent, and the token goes only to the run's own host: the JSON plan and the plan's log
/// are served from signed links elsewhere, which are fetched without it. A finished plan never
/// changes, so what's read of one is kept in memory for as long as the app runs.
public struct TerraformCloudRuns: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let token: @Sendable (String) -> String?
    private let transport: Transport
    private let kept = KeptPlans()

    /// With the token for each run's host from `TF_TOKEN_<host>`, as Terraform reads it, else
    /// from `credentials`, where `terraform login` stores it. Read afresh for each run, so a new
    /// login is picked up without restarting.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, credentials: URL = Self.credentialsFile, transport: @escaping Transport = TerraformCloudRuns.urlSession) {
        token = { host in TerraformCredentials.token(for: host, environment: environment, file: credentials) }
        self.transport = transport
    }

    /// With `token` always, as the fakes take.
    public init(token: String, transport: @escaping Transport) {
        self.token = { _ in token }
        self.transport = transport
    }

    /// With the process's environment and `terraform login`'s credentials.
    public static func live() -> TerraformCloudRuns {
        TerraformCloudRuns(environment: ProcessInfo.processInfo.environment, credentials: credentialsFile, transport: urlSession)
    }

    /// Where `terraform login` stores its tokens.
    public static let credentialsFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".terraform.d/credentials.tfrc.json")

    /// Follows no redirects, so Loupe follows them itself without the token.
    public static let urlSession: Transport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    }()

    /// Why a run couldn't be read.
    public enum Failure: Error, Sendable, Equatable {
        /// There's no token for the host, so `terraform login` is needed.
        case signedOut(host: String)
        /// The host turned the token down.
        case refused(host: String)
        /// No such run, or none this token can see, which Terraform Cloud answers alike.
        case notFound
        /// Anything else, in its own words.
        case failed(String)
    }

    /// Whether there's a token for `host`, without asking it anything.
    public func hasToken(for host: String) -> Bool {
        token(host) != nil
    }

    /// The run's plan: what it would change once planned, what went wrong if it errored, or
    /// where it has got to if it hasn't finished.
    public func plan(of check: TerraformPlanCheck) async throws(Failure) -> TerraformRunPlan {
        if let plan = await kept.plan(check.runId) { return plan }
        let host = check.host
        guard let token = token(host) else { throw .signedOut(host: host) }
        let run: Document<RunWire> = try await decode(get(api(host, "runs/\(check.runId)", query: [URLQueryItem(name: "include", value: "plan")]), token: token, host: host))
        guard let planId = run.data.relationships.plan?.data?.id else {
            return .unfinished(status: run.data.attributes.status)
        }
        let attributes = run.included?.first { $0.id == planId }?.attributes
        let result: TerraformRunPlan
        switch attributes?.status {
        case "finished":
            let data = try await get(api(host, "plans/\(planId)/json-output"), token: token, host: host)
            do {
                result = .planned(try TerraformPlan(json: data))
            } catch {
                throw .failed("Terraform Cloud's JSON plan couldn't be read: \(error)")
            }
        case "errored":
            var log = ""
            if let url = attributes?.logReadURL.flatMap(URL.init(string:)) {
                log = String(decoding: try await get(url, token: nil, host: host), as: UTF8.self)
            }
            result = .errored(log: TerraformLog.errors(in: log))
        default:
            return .unfinished(status: attributes?.status ?? run.data.attributes.status)
        }
        await kept.keep(result, for: check.runId)
        return result
    }

    private func api(_ host: String, _ path: String, query: [URLQueryItem] = []) -> URL {
        var url = URL(string: "https://\(host)/api/v2/")!.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        return url
    }

    /// GETs `url`, with the token only when it's the host's API, following redirects over https
    /// without it.
    private func get(_ url: URL, token: String?, host: String) async throws(Failure) -> Data {
        var url = url
        var token = token
        for _ in 0..<5 {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
            if let token, url.host() == host { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport(request)
            } catch {
                throw .failed(error.localizedDescription)
            }
            switch response.statusCode {
            case 200...299:
                return data
            case 301, 302, 303, 307, 308:
                guard let location = response.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0, relativeTo: url)?.absoluteURL }),
                      location.scheme == "https" else { throw .failed("Terraform Cloud sent Loupe somewhere it won't follow.") }
                url = location
                token = nil
            case 401, 403:
                throw .refused(host: host)
            case 404:
                throw .notFound
            default:
                let said = (try? JSONDecoder().decode(ErrorsWire.self, from: data))?.errors.first.map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: ": ") }
                throw .failed(said ?? "Terraform Cloud answered \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode)).")
            }
        }
        throw .failed("Terraform Cloud redirected too many times.")
    }

    private func decode<T: Decodable>(_ data: Data) throws(Failure) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .failed("Terraform Cloud's answer couldn't be read: \(error)")
        }
    }
}

/// What a run's plan came to.
public enum TerraformRunPlan: Sendable, Equatable {
    case planned(TerraformPlan)
    /// The plan errored; its log's errors, as Terraform prints them.
    case errored(log: String)
    /// The run hasn't planned yet, or never will: Terraform Cloud's word for where it is.
    case unfinished(status: String)
}

extension TerraformCloudRuns.Failure {
    public var title: String {
        switch self {
        case let .signedOut(host): "Terraform isn't signed in to \(host)"
        case let .refused(host): "\(host) turned Terraform's sign-in down"
        case .notFound: "Terraform Cloud couldn't find the run"
        case .failed: "Couldn't read Terraform Cloud"
        }
    }

    /// Markdown, for the commands to type in code.
    public var message: String {
        switch self {
        case let .signedOut(host), let .refused(host):
            "Loupe reads plans with the token `terraform login` stores. Sign in with `\(host == "app.terraform.io" ? "terraform login" : "terraform login \(host)")`, then try again."
        case .notFound:
            "It may have been deleted, or `terraform login` may be signed in to an account that can't see it."
        case let .failed(said):
            said
        }
    }
}

/// Reads tokens as Terraform does: `TF_TOKEN_<host>`, the host's dots as underscores and its
/// dashes as double underscores, else the host's entry in `credentials.tfrc.json`.
enum TerraformCredentials {
    static func token(for host: String, environment: [String: String], file: URL) -> String? {
        let variable = "TF_TOKEN_" + host.replacingOccurrences(of: "-", with: "__").replacingOccurrences(of: ".", with: "_")
        if let token = environment[variable], !token.isEmpty { return token }
        guard let data = try? Data(contentsOf: file),
              let credentials = try? JSONDecoder().decode(CredentialsFile.self, from: data),
              let token = credentials.credentials[host]?.token, !token.isEmpty else { return nil }
        return token
    }

    private struct CredentialsFile: Decodable {
        let credentials: [String: Host]

        struct Host: Decodable {
            let token: String?
        }
    }
}

/// A plan's log as Terraform prints its errors: each error diagnostic of the structured log
/// in the CLI's box, or the log as it is when it isn't structured.
enum TerraformLog {
    static func errors(in log: String) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        let diagnostics = lines.compactMap { line -> DiagnosticWire? in
            guard line.hasPrefix("{"), let entry = try? JSONDecoder().decode(LogLineWire.self, from: Data(line.utf8)), entry.type == "diagnostic" else { return nil }
            return entry.diagnostic
        }
        let errors = diagnostics.filter { $0.severity == "error" }
        guard !errors.isEmpty else {
            return lines.filter { !$0.hasPrefix("{") }.joined(separator: "\n")
        }
        return errors.map(box).joined(separator: "\n")
    }

    private static func box(_ diagnostic: DiagnosticWire) -> String {
        var body = ["\u{1B}[31m\u{1B}[1mError: \u{1B}[0m\u{1B}[1m\(diagnostic.summary)\u{1B}[0m", ""]
        if let range = diagnostic.range {
            let context = diagnostic.snippet?.context.map { ", in \($0)" } ?? ""
            body.append("  on \(range.filename) line \(range.start.line)\(context):")
            if let snippet = diagnostic.snippet {
                for (offset, code) in snippet.code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    body.append(String(format: "%4d: ", snippet.startLine + offset) + code)
                }
            }
            body.append("")
        }
        if let detail = diagnostic.detail, !detail.isEmpty { body += detail.components(separatedBy: "\n") }
        let red = "\u{1B}[31m"
        let reset = "\u{1B}[0m"
        return ([red + "╷" + reset] + body.map { red + "│" + reset + " " + $0 } + [red + "╵" + reset]).joined(separator: "\n") + "\n"
    }

    private struct LogLineWire: Decodable {
        let type: String?
        let diagnostic: DiagnosticWire?
    }

    private struct DiagnosticWire: Decodable {
        let severity: String
        let summary: String
        let detail: String?
        let range: Range?
        let snippet: Snippet?

        struct Range: Decodable {
            let filename: String
            let start: Position
        }

        struct Position: Decodable {
            let line: Int
        }

        struct Snippet: Decodable {
            let context: String?
            let code: String
            let startLine: Int

            enum CodingKeys: String, CodingKey {
                case context, code
                case startLine = "start_line"
            }
        }
    }
}

/// The plans of runs that have finished planning.
private actor KeptPlans {
    private var plans: [String: TerraformRunPlan] = [:]

    func plan(_ runId: String) -> TerraformRunPlan? { plans[runId] }
    func keep(_ plan: TerraformRunPlan, for runId: String) { plans[runId] = plan }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

private struct Document<T: Decodable>: Decodable {
    let data: T
    let included: [IncludedWire]?
}

private struct RunWire: Decodable {
    let attributes: Attributes
    let relationships: Relationships

    struct Attributes: Decodable {
        let status: String
    }

    struct Relationships: Decodable {
        let plan: Relationship?
    }

    struct Relationship: Decodable {
        let data: Reference?
    }

    struct Reference: Decodable {
        let id: String
    }
}

private struct IncludedWire: Decodable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let status: String?
        let logReadURL: String?

        enum CodingKeys: String, CodingKey {
            case status
            case logReadURL = "log-read-url"
        }
    }
}

private struct ErrorsWire: Decodable {
    let errors: [Entry]

    struct Entry: Decodable {
        let title: String?
        let detail: String?
    }
}
