import Foundation
import LoupeModel

/// Reads CircleCI jobs, their steps' output, failed tests and artifacts, from the v3 API the
/// `circleci` CLI uses, with the token the CLI is signed in with. Only GETs are sent, and the
/// token goes only to the API's host. A job that has ended never changes, so what's read of one
/// is kept in memory for as long as the app runs.
public struct CircleCIJobs: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let host: URL
    private let token: CLIToken
    private let transport: Transport
    private let kept = Kept()

    /// With the token printed by `LOUPE_CIRCLECI_TOKEN_COMMAND`, else by `tokenCommand`.
    public init(host: URL = Self.host, environment: [String: String] = ProcessInfo.processInfo.environment, tokenCommand: URL? = nil, transport: @escaping Transport = CircleCIJobs.urlSession) {
        self.host = host
        let command = environment["LOUPE_CIRCLECI_TOKEN_COMMAND"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) } ?? tokenCommand
        token = CLIToken(command: command, environment: environment)
        self.transport = transport
    }

    /// With `token` always, as the fakes take.
    public init(host: URL = Self.host, token: String, transport: @escaping Transport) {
        self.host = host
        self.token = CLIToken(fixed: token)
        self.transport = transport
    }

    /// With the token read by the app's `circleci-token` script.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> CircleCIJobs {
        CircleCIJobs(environment: environment, tokenCommand: CircleCIArtifacts.tokenScript)
    }

    public static let host = URL(string: "https://circleci.com")!

    public static let urlSession: Transport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    }()

    /// Why CircleCI couldn't be read.
    public enum Failure: Error, Sendable, Equatable {
        /// The CLI isn't signed in, so there's no token.
        case signedOut
        /// CircleCI turned the token down.
        case refused
        /// CircleCI has no such job, or won't say to this token.
        case notFound
        /// Anything else, in its own words.
        case failed(String)
    }

    /// The failed jobs `checks` lead to, each once, in the checks' order. A check linking only
    /// a workflow leads to its job of the check's name, else to each job of it that failed.
    public func failedJobs(of checks: [FailedCircleCICheck]) async throws(Failure) -> [CircleCIJob] {
        var ids: [String] = []
        for check in checks {
            for id in try await jobIds(of: check) where !ids.contains(id) {
                ids.append(id)
            }
        }
        var jobs: [CircleCIJob] = []
        for id in ids {
            jobs.append(try await job(id))
        }
        return jobs
    }

    public func job(_ id: String) async throws(Failure) -> CircleCIJob {
        if let job = await kept.job(id) { return job }
        let wire: Entity<JobWire> = try await decode(get("api/v3/jobs/\(id)"))
        let job = wire.data.job
        if job.hasEnded { await kept.keep(job) }
        return job
    }

    /// What the step printed, its standard error after its standard output, with the terminal's
    /// escapes as printed.
    public func output(of step: CircleCIStep, in job: CircleCIJob) async throws(Failure) -> String {
        let key = "\(job.id)/\(step.id)"
        if let output = await kept.output(key) { return output }
        let filter = [URLQueryItem(name: "filter[execution]", value: "\(step.execution)"), URLQueryItem(name: "filter[step_num]", value: "\(step.number)")]
        let stdout = try await get("api/v3/jobs/\(job.id)/stdout", query: filter)
        let stderr = try await get("api/v3/jobs/\(job.id)/stderr", query: filter)
        let output = [stdout, stderr].map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }.joined(separator: "\n")
        if job.hasEnded && step.outcome != nil { await kept.keep(output: output, for: key) }
        return output
    }

    /// The tests the job's stored results say failed, from every execution.
    public func failedTests(of job: CircleCIJob) async throws(Failure) -> [CircleCITestFailure] {
        if let tests = await kept.tests(job.id) { return tests }
        let data = try await get("api/v3/jobs/\(job.id)/tests")
        let results = data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder.circleCI.decode(TestResultWire.self, from: Data($0)) }
        let tests = results.filter { !["success", "skipped"].contains($0.result) }.enumerated().map { index, result in
            CircleCITestFailure(id: index, classname: result.classname ?? "", name: result.name ?? "", message: result.message ?? "", runTime: result.runTime)
        }
        if job.hasEnded { await kept.keep(tests: tests, for: job.id) }
        return tests
    }

    /// The files the job kept; none when it kept none, which CircleCI answers as not found.
    public func artifacts(of job: CircleCIJob) async throws(Failure) -> [CircleCIArtifact] {
        if let artifacts = await kept.artifacts(job.id) { return artifacts }
        let artifacts: [CircleCIArtifact]
        do throws(Failure) {
            let list: List<ArtifactWire> = try await decode(get("api/v3/jobs/\(job.id)/artifacts"))
            artifacts = list.data.compactMap(\.artifact)
        } catch .notFound {
            artifacts = []
        }
        if job.hasEnded { await kept.keep(artifacts: artifacts, for: job.id) }
        return artifacts
    }

    private func jobIds(of check: FailedCircleCICheck) async throws(Failure) -> [String] {
        switch check.link {
        case let .job(id):
            return [id]
        case let .workflow(id, number):
            return try await jobIds(inWorkflow: id, number: number, name: check.name)
        case let .numbered(project, number):
            // The v3 API knows jobs only by id, so the job's workflow is found from the v2 API's
            // job by number, and the job among the workflow's.
            let numbered: NumberedJobWire = try await decode(get("api/v2/project/\(project)/job/\(number)"))
            guard let workflow = numbered.latestWorkflow?.id else { throw .notFound }
            return try await jobIds(inWorkflow: workflow, number: number, name: check.name)
        }
    }

    private func jobIds(inWorkflow workflow: String, number: Int?, name: String) async throws(Failure) -> [String] {
        var jobs: [WorkflowJobWire] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "filter[workflow_id]", value: workflow)]
            if let cursor { query.append(URLQueryItem(name: "page[cursor]", value: cursor)) }
            let page: List<WorkflowJobWire> = try await decode(get("api/v3/jobs", query: query))
            jobs += page.data
            cursor = page.page?.next
        } while cursor != nil
        if let number, let job = jobs.first(where: { $0.attributes.number == number }) { return [job.id] }
        if let job = jobs.first(where: { $0.attributes.name == name }) { return [job.id] }
        return jobs.filter { $0.attributes.outcome == "failed" }.map(\.id)
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws(Failure) -> Data {
        guard let current = await token.current() else { throw .signedOut }
        var (data, response) = try await send(path, query: query, token: current)
        if [401, 403].contains(response.statusCode) {
            guard let renewed = await token.renewed(after: current), renewed != current else { throw .refused }
            (data, response) = try await send(path, query: query, token: renewed)
        }
        switch response.statusCode {
        case 200...299: return data
        case 401, 403: throw .refused
        case 404: throw .notFound
        default:
            let said = (try? JSONDecoder().decode(ErrorWire.self, from: data))?.message
            throw .failed(said ?? "CircleCI answered \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode)).")
        }
    }

    private func send(_ path: String, query: [URLQueryItem], token: String) async throws(Failure) -> (Data, HTTPURLResponse) {
        var url = host.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            return try await transport(request)
        } catch {
            throw .failed(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws(Failure) -> T {
        do {
            return try JSONDecoder.circleCI.decode(T.self, from: data)
        } catch {
            throw .failed("CircleCI's answer couldn't be read: \(error)")
        }
    }
}

extension CircleCIJobs.Failure {
    public var title: String {
        switch self {
        case .signedOut: "The circleci CLI isn't signed in"
        case .refused: "CircleCI turned the circleci CLI's sign-in down"
        case .notFound: "CircleCI couldn't find the job"
        case .failed: "Couldn't read CircleCI"
        }
    }

    /// Markdown, for the commands to type in code.
    public var message: String {
        switch self {
        case .signedOut, .refused:
            "Loupe reads CircleCI with the token the `circleci` CLI is signed in with. Sign it in with `circleci auth login`, then try again."
        case .notFound:
            "It may have been deleted, or the `circleci` CLI may be signed in to an account that can't see it."
        case let .failed(said):
            said
        }
    }
}

/// What's been read of jobs that have ended.
private actor Kept {
    private var jobs: [String: CircleCIJob] = [:]
    private var outputs: [String: String] = [:]
    private var tests: [String: [CircleCITestFailure]] = [:]
    private var artifacts: [String: [CircleCIArtifact]] = [:]

    func job(_ id: String) -> CircleCIJob? { jobs[id] }
    func output(_ key: String) -> String? { outputs[key] }
    func tests(_ id: String) -> [CircleCITestFailure]? { tests[id] }
    func artifacts(_ id: String) -> [CircleCIArtifact]? { artifacts[id] }

    func keep(_ job: CircleCIJob) { jobs[job.id] = job }
    func keep(output: String, for key: String) { outputs[key] = output }
    func keep(tests: [CircleCITestFailure], for id: String) { self.tests[id] = tests }
    func keep(artifacts: [CircleCIArtifact], for id: String) { self.artifacts[id] = artifacts }
}

private struct Entity<T: Decodable>: Decodable {
    let data: T
}

private struct List<T: Decodable>: Decodable {
    let data: [T]
    let page: Page?

    struct Page: Decodable {
        let next: String?
    }
}

private struct JobWire: Decodable {
    let id: String
    let attributes: Attributes
    let references: References?

    struct Attributes: Decodable {
        let name: String
        let phase: String?
        let outcome: String?
        let parallelExecutions: [Execution]?
    }

    struct Execution: Decodable {
        let steps: [Step]
    }

    struct Step: Decodable {
        let name: String
        let num: Int
        let outcome: String?
        let exitCode: Int?
        let command: String?
    }

    struct References: Decodable {
        let workflow: Reference?
    }

    struct Reference: Decodable {
        let id: String
    }

    var job: CircleCIJob {
        let executions = attributes.parallelExecutions ?? []
        let steps = executions.enumerated().flatMap { index, execution in
            execution.steps.map { CircleCIStep(execution: index, number: $0.num, name: $0.name, outcome: $0.outcome.flatMap { $0.isEmpty ? nil : $0 }, exitCode: $0.exitCode, command: $0.command) }
        }
        let outcome = attributes.phase == "ended" ? attributes.outcome.flatMap { $0.isEmpty ? nil : $0 } : nil
        return CircleCIJob(id: id.lowercased(), name: attributes.name, outcome: outcome, workflowId: references?.workflow?.id.lowercased(), steps: steps, executionCount: max(executions.count, 1))
    }
}

private struct WorkflowJobWire: Decodable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let number: Int?
        let name: String
        let outcome: String?
    }
}

private struct NumberedJobWire: Decodable {
    let latestWorkflow: Workflow?

    struct Workflow: Decodable {
        let id: String
    }
}

private struct TestResultWire: Decodable {
    let classname: String?
    let name: String?
    let result: String
    let runTime: Double?
    let message: String?
}

private struct ArtifactWire: Decodable {
    let attributes: Attributes

    struct Attributes: Decodable {
        let path: String
        let url: String
        let execution: Int?
    }

    var artifact: CircleCIArtifact? {
        URL(string: attributes.url).map { CircleCIArtifact(path: attributes.path, url: $0, execution: attributes.execution ?? 0) }
    }
}

private struct ErrorWire: Decodable {
    let message: String
}

private extension JSONDecoder {
    static let circleCI: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
