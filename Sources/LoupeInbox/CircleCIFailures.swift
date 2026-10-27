import Foundation
import LoupeModel

/// What CircleCI says of a PR's failed jobs, for its CircleCI pane: each job the failed checks
/// lead to, and for the job shown, its failed steps' output, its failed tests and its artifacts.
/// Each is read when first shown and kept.
@Observable
@MainActor
public final class CircleCIFailures {
    public enum Panel: Hashable, Sendable, CaseIterable {
        case steps, tests, artifacts
    }

    public enum Loading<Value: Sendable>: Sendable {
        case loading
        case loaded(Value)
        case failed(CircleCIJobs.Failure)

        public var value: Value? {
            if case let .loaded(value) = self { value } else { nil }
        }
    }

    /// The failed checks the jobs were found from.
    public private(set) var checks: [FailedCircleCICheck] = []
    public private(set) var jobs: Loading<[CircleCIJob]> = .loading
    public private(set) var selectedJobId: String?
    public var panel: Panel = .steps
    private(set) var selectedStepIds: [String: String] = [:]
    public var selectedTestIds: [String: Int] = [:]
    public private(set) var tests: [String: Loading<[CircleCITestFailure]>] = [:]
    public private(set) var artifacts: [String: Loading<[CircleCIArtifact]>] = [:]
    /// By job and step.
    private var outputs: [String: Loading<String>] = [:]

    private let client: CircleCIJobs

    public init(client: CircleCIJobs) {
        self.client = client
    }

    public var selectedJob: CircleCIJob? {
        jobs.value?.first { $0.id == selectedJobId }
    }

    /// Finds the jobs `checks` lead to, unless they're those already found, and shows the first,
    /// or the one shown before if it's still among them.
    public func show(_ checks: [FailedCircleCICheck]) async {
        if checks == self.checks, jobs.value != nil { return }
        self.checks = checks
        jobs = .loading
        let found: Loading<[CircleCIJob]>
        do {
            found = .loaded(try await client.failedJobs(of: checks))
        } catch {
            found = .failed(error)
        }
        guard checks == self.checks else { return }
        jobs = found
        let shown = found.value?.first { $0.id == selectedJobId } ?? found.value?.first
        selectedJobId = shown?.id
        if let shown { await load(shown) }
    }

    /// Looks for the jobs again after a failure.
    public func retry() async {
        let checks = checks
        self.checks = []
        await show(checks)
    }

    public func select(job id: String) async {
        selectedJobId = id
        if let job = selectedJob { await load(job) }
    }

    /// The step whose output is shown in `job`: the one picked, else its first failed step.
    public func selectedStep(in job: CircleCIJob) -> CircleCIStep? {
        let failed = job.failedSteps
        return failed.first { $0.id == selectedStepIds[job.id] } ?? failed.first
    }

    public func select(step: CircleCIStep, in job: CircleCIJob) async {
        selectedStepIds[job.id] = step.id
        await loadOutput(of: step, in: job)
    }

    public func output(of step: CircleCIStep, in job: CircleCIJob) -> Loading<String>? {
        outputs["\(job.id)/\(step.id)"]
    }

    /// Reads again whatever of `job` failed to be read.
    public func retry(_ job: CircleCIJob) async {
        for (key, loading) in outputs where key.hasPrefix("\(job.id)/") {
            if case .failed = loading { outputs[key] = nil }
        }
        if case .failed? = tests[job.id] { tests[job.id] = nil }
        if case .failed? = artifacts[job.id] { artifacts[job.id] = nil }
        await load(job)
    }

    /// Reads the job's failed tests, its artifacts and its shown step's output, those not
    /// already read, at once.
    private func load(_ job: CircleCIJob) async {
        let step = selectedStep(in: job)
        async let tests: Void = loadTests(of: job)
        async let artifacts: Void = loadArtifacts(of: job)
        if let step { await loadOutput(of: step, in: job) }
        _ = await (tests, artifacts)
    }

    private func loadTests(of job: CircleCIJob) async {
        guard tests[job.id] == nil else { return }
        tests[job.id] = .loading
        do {
            tests[job.id] = .loaded(try await client.failedTests(of: job))
        } catch {
            tests[job.id] = .failed(error)
        }
    }

    private func loadArtifacts(of job: CircleCIJob) async {
        guard artifacts[job.id] == nil else { return }
        artifacts[job.id] = .loading
        do {
            artifacts[job.id] = .loaded(try await client.artifacts(of: job))
        } catch {
            artifacts[job.id] = .failed(error)
        }
    }

    private func loadOutput(of step: CircleCIStep, in job: CircleCIJob) async {
        let key = "\(job.id)/\(step.id)"
        guard outputs[key] == nil else { return }
        outputs[key] = .loading
        do {
            outputs[key] = .loaded(try await client.output(of: step, in: job))
        } catch {
            outputs[key] = .failed(error)
        }
    }
}
