import Foundation

/// CircleCI's API as the `circleci` CLI reads it, over jobs held in memory: v3's jobs with their
/// steps, each step's output, a workflow's jobs, a job's stored test results and its artifacts,
/// and v2's job by number for finding an older project's job. It refuses any token but `token`,
/// answers a job with no artifacts as not found as CircleCI does, and records each path asked
/// for, so tests can see what was read again.
public actor FakeCircleCI {
    public static let token = "fake-circleci-token"
    public static let host = "circleci.com"

    public struct Job: Sendable {
        public var id: String
        public var number: Int
        public var name: String
        /// Such as "gh/org/repo".
        public var project: String
        public var workflow: String
        /// Nil while it runs.
        public var outcome: String?
        public var executions: [[Step]]
        /// Nil when it stored none.
        public var tests: [Test]?
        public var artifacts: [String]

        public init(id: String, number: Int, name: String, project: String, workflow: String, outcome: String?, executions: [[Step]], tests: [Test]? = nil, artifacts: [String] = []) {
            self.id = id
            self.number = number
            self.name = name
            self.project = project
            self.workflow = workflow
            self.outcome = outcome
            self.executions = executions
            self.tests = tests
            self.artifacts = artifacts
        }
    }

    public struct Step: Sendable {
        public var number: Int
        public var name: String
        public var type: String
        public var outcome: String
        public var exitCode: Int?
        public var command: String?
        public var stdout: String
        public var stderr: String

        public init(number: Int, name: String, type: String = "run", outcome: String = "succeeded", exitCode: Int? = nil, command: String? = nil, stdout: String = "", stderr: String = "") {
            self.number = number
            self.name = name
            self.type = type
            self.outcome = outcome
            self.exitCode = exitCode ?? (type == "run" ? (outcome == "succeeded" ? 0 : 1) : nil)
            self.command = command ?? (type == "run" ? name : nil)
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public struct Test: Sendable {
        public var classname: String
        public var name: String
        public var result: String
        public var runTime: Double
        public var message: String

        public init(classname: String, name: String, result: String, runTime: Double = 1, message: String = "") {
            self.classname = classname
            self.name = name
            self.result = result
            self.runTime = runTime
            self.message = message
        }
    }

    private var jobs: [Job]
    /// Each path asked for, with its query, in order.
    public private(set) var requests: [String] = []
    /// How many jobs a page of a workflow's lists.
    private let pageSize: Int

    public init(jobs: [Job] = [], pageSize: Int = 100) {
        self.jobs = jobs
        self.pageSize = pageSize
    }

    /// The failed jobs of `tamarinworks/marmot#14268` in `probe/pr-status.json`.
    public static func fixture() -> FakeCircleCI {
        FakeCircleCI(jobs: fixtureJobs)
    }

    public func add(_ job: Job) {
        jobs.append(job)
    }

    public func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try require(request.url)
        try expect(url.host() == Self.host, "a request for \(url.absoluteString), which isn't CircleCI's API")
        try expect((request.httpMethod ?? "GET") == "GET", "a \(request.httpMethod ?? "") to CircleCI, which Loupe only reads")
        requests.append(url.query().map { "\(url.path())?\($0)" } ?? url.path())
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" else {
            return json(["message": "Invalid token provided."], url, status: 401)
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? []) { $1 }
        switch parts.prefix(3) {
        case ["api", "v3", "jobs"] where parts.count == 3:
            return try workflowJobs(query, url)
        case ["api", "v3", "jobs"]:
            guard let job = jobs.first(where: { $0.id == parts[3] }) else { return notFound(url) }
            switch Array(parts.dropFirst(4)) {
            case []: return json(["data": wire(job)], url)
            case ["stdout"]: return try output(of: job, query, url) { $0.stdout }
            case ["stderr"]: return try output(of: job, query, url) { $0.stderr }
            case ["tests"]: return tests(of: job, url)
            case ["artifacts"]: return artifacts(of: job, url)
            default: throw mismatch("unknown", "no fake CircleCI answers \(url.path())")
            }
        case ["api", "v2", "project"]:
            // project/<vcs>/<org>/<repo>/job/<number>
            guard parts.count == 8, parts[6] == "job", let number = Int(parts[7]) else { throw mismatch("unknown", "no fake CircleCI answers \(url.path())") }
            let project = parts[3...5].joined(separator: "/")
            guard let job = jobs.first(where: { $0.project == project && $0.number == number }) else { return notFound(url) }
            return json(["number": job.number, "name": job.name, "status": job.outcome == "succeeded" ? "success" : job.outcome ?? "running", "latest_workflow": ["id": job.workflow, "name": "build"], "project": ["slug": job.project]], url)
        default:
            throw mismatch("unknown", "no fake CircleCI answers \(url.path())")
        }
    }

    private func workflowJobs(_ query: [String: String], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let workflow = try require(query["filter[workflow_id]"], "a list of jobs without a workflow")
        let all = jobs.filter { $0.workflow == workflow }
        let start = query["page[cursor]"].flatMap(Int.init) ?? 0
        let page = all.dropFirst(start).prefix(pageSize)
        var body: [String: Any] = ["data": page.map { job in
            ["id": job.id, "attributes": ["number": job.number, "name": job.name, "type": "build", "phase": job.outcome == nil ? "started" : "ended", "outcome": job.outcome ?? ""] as [String: Any], "references": ["workflow": ["id": job.workflow]]] as [String: Any]
        }]
        if start + pageSize < all.count { body["page"] = ["next": "\(start + pageSize)"] }
        return json(body, url)
    }

    private func output(of job: Job, _ query: [String: String], _ url: URL, _ text: (Step) -> String) throws -> (Data, HTTPURLResponse) {
        let execution = try require(query["filter[execution]"].flatMap(Int.init), "step output without an execution")
        let number = try require(query["filter[step_num]"].flatMap(Int.init), "step output without a step number")
        guard job.executions.indices.contains(execution), let step = job.executions[execution].first(where: { $0.number == number }) else { return notFound(url) }
        return (Data(text(step).utf8), response(url, status: 200, type: "application/octet-stream"))
    }

    private func tests(of job: Job, _ url: URL) -> (Data, HTTPURLResponse) {
        let lines = (job.tests ?? []).map { test in
            let object: [String: Any] = ["classname": test.classname, "name": test.name, "result": test.result, "run_time": test.runTime, "message": test.message]
            return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        return (Data(lines.map { "\($0)\n" }.joined().utf8), response(url, status: 200, type: "application/jsonl"))
    }

    private func artifacts(of job: Job, _ url: URL) -> (Data, HTTPURLResponse) {
        guard !job.artifacts.isEmpty else {
            return json(["message": "No resource found for \"\(job.id)\"."], url, status: 404)
        }
        return json(["data": job.artifacts.map { path in
            ["attributes": ["path": path, "url": "https://output.circle-artifacts.com/output/job/\(job.id)/artifacts/0/\(path)", "execution": 0] as [String: Any]]
        }], url)
    }

    private func wire(_ job: Job) -> [String: Any] {
        let executions = job.executions.map { steps in
            ["steps": steps.map { step in
                var wire: [String: Any] = ["name": step.name, "type": step.type, "num": step.number, "phase": "ended", "outcome": step.outcome, "is_insignificant": false, "stdout_bytes": step.stdout.utf8.count, "stderr_bytes": step.stderr.utf8.count, "started_at": "2026-10-20T10:00:00Z", "ended_at": "2026-10-20T10:01:00Z"]
                if let exitCode = step.exitCode { wire["exit_code"] = exitCode }
                if let command = step.command { wire["command"] = command }
                return wire
            }]
        }
        let attributes: [String: Any] = ["name": job.name, "type": "build", "phase": job.outcome == nil ? "started" : "ended", "outcome": job.outcome ?? "", "started_at": "2026-10-20T10:00:00Z", "parallel_executions": executions]
        return ["id": job.id, "attributes": attributes, "references": ["workflow": ["id": job.workflow], "project": ["id": "00000000-0000-4000-8000-000000000001"]]]
    }

    private func json(_ object: Any, _ url: URL, status: Int = 200) -> (Data, HTTPURLResponse) {
        ((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), response(url, status: status, type: "application/json"))
    }

    private func notFound(_ url: URL) -> (Data, HTTPURLResponse) {
        json(["message": "Not found."], url, status: 404)
    }

    private func response(_ url: URL, status: Int, type: String) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
    }
}

private let esc = "\u{1B}"

private let fixtureJobs: [FakeCircleCI.Job] = [
    FakeCircleCI.Job(
        id: "996a9423-261e-5bcb-b71f-e15bc467d7ae", number: 43117, name: "playwright", project: "gh/tamarinworks/marmot",
        workflow: "38f76f1c-9800-7454-8f63-a838bc6fff99", outcome: "failed",
        executions: (0..<2).map { execution in
            setup + [
                FakeCircleCI.Step(number: 106, name: "playwright", outcome: "failed", command: "npx playwright test --shard=\(execution + 1)/2", stdout: playwrightOutput(shard: execution + 1)),
                FakeCircleCI.Step(number: 107, name: "Uploading test results", type: "store_test_results"),
            ]
        },
        tests: [
            FakeCircleCI.Test(classname: "e2e/boards.spec.ts", name: "a board keeps its layout after a reload", result: "failure", runTime: 41.2, message: "TimeoutError: locator.waitFor: Timeout 40000ms exceeded.\nCall log:\n  - waiting for getByRole('grid', { name: 'Board' }) to be visible\n\n    at e2e/boards.spec.ts:58:21"),
            FakeCircleCI.Test(classname: "e2e/boards.spec.ts", name: "a board's tiles can be dragged", result: "success", runTime: 6.1),
            FakeCircleCI.Test(classname: "e2e/sharing.spec.ts", name: "a shared link opens read-only", result: "failure", runTime: 12.8, message: "Error: expect(received).toHaveText(expected)\n\nExpected: \"Read only\"\nReceived: \"Edit\"\n\n    at e2e/sharing.spec.ts:24:7"),
            FakeCircleCI.Test(classname: "e2e/sharing.spec.ts", name: "a link can be revoked", result: "skipped"),
        ],
        artifacts: ["playwright-report/index.html", "playwright-report/data/trace.zip", "test-results/boards-a-board-keeps-its-layout/test-failed-1.png"]
    ),
    FakeCircleCI.Job(
        id: "c0555525-bd97-b6dd-530a-7ffc511c2525", number: 43115, name: "typecheck", project: "gh/tamarinworks/marmot",
        workflow: "38f76f1c-9800-7454-8f63-a838bc6fff99", outcome: "failed",
        executions: [setup + [
            FakeCircleCI.Step(number: 106, name: "Typecheck", outcome: "failed", exitCode: 2, command: "npx tsc --noEmit", stdout: "src/boards/layout.ts(42,7): error TS2322: Type 'string' is not assignable to type 'number'.\nsrc/boards/tile.tsx(17,3): error TS2741: Property 'size' is missing in type '{}' but required in type 'TileProps'.\n\(esc)[31mFound 2 errors in 2 files.\(esc)[0m\n"),
        ]]
    ),
]

private let setup = [
    FakeCircleCI.Step(number: 0, name: "Spin up environment", type: "spinup_environment", stdout: "Build-agent version 1.0.0\nStarting container cimg/node:22.11\n"),
    FakeCircleCI.Step(number: 101, name: "Checkout code", type: "checkout", stdout: "Cloning into '.'...\n"),
    FakeCircleCI.Step(number: 104, name: "npm ci", stdout: "added 1204 packages in 31s\n"),
]

private func playwrightOutput(shard: Int) -> String {
    "\r\nRunning 20 tests using 4 workers, shard \(shard) of 2\r\n\r\n"
        + "  \(esc)[32m✓\(esc)[39m  1 \(esc)[2m[chromium] › \(esc)[22me2e/boards.spec.ts:12:5 › a board's tiles can be dragged \(esc)[2m(6.1s)\(esc)[22m\r\n"
        + "  \(esc)[31m✘\(esc)[39m  2 \(esc)[2m[chromium] › \(esc)[22me2e/boards.spec.ts:58:5 › a board keeps its layout after a reload \(esc)[2m(41.2s)\(esc)[22m\r\n"
        + "[3/20] Running…\r[4/20] Running…\r[20/20] Done\r\n\r\n"
        + "  1) [chromium] › e2e/boards.spec.ts:58:5 › a board keeps its layout after a reload\r\n\r\n"
        + "    \(esc)[31mTimeoutError: locator.waitFor: Timeout 40000ms exceeded.\(esc)[39m\r\n\r\n"
        + "  \(esc)[1m\(esc)[31m2 failed\(esc)[39m\(esc)[22m\r\n  \(esc)[32m18 passed\(esc)[39m \(esc)[2m(1.2m)\(esc)[22m\r\n"
}
