import Foundation

/// A failed check that CircleCI ran, by the short name the header shows and where its link
/// points in CircleCI.
public struct FailedCircleCICheck: Sendable, Hashable {
    public var name: String
    public var link: CircleCIJobLink

    public init(name: String, link: CircleCIJobLink) {
        self.name = name
        self.link = link
    }
}

extension [CheckContext] {
    /// The failed checks whose links lead to CircleCI, in GitHub's order. Tolerated failures are
    /// left out, as they don't make the checks fail.
    public var failedCircleCIChecks: [FailedCircleCICheck] {
        compactMap { context in
            guard context.status == .failure, !context.isToleratedFailure,
                  let link = context.url.flatMap(CircleCIJobLink.init(url:)) else { return nil }
            return FailedCircleCICheck(name: shortName(context.name), link: link)
        }
    }
}

/// What a check's link says of the CircleCI job it's for. Commit statuses link the job itself,
/// by id or, from older projects, by its number in the project; check runs and some statuses link
/// only the workflow, perhaps with the job's number.
public enum CircleCIJobLink: Sendable, Hashable {
    case job(id: String)
    case workflow(id: String, jobNumber: Int?)
    /// A job by its number in a project, such as "gh/org/repo".
    case numbered(project: String, number: Int)

    /// Reads `app.circleci.com/workflow/<id>/job/<id>`, `app.circleci.com/pipelines/<vcs>/<org>/
    /// <repo>/<n>/workflows/<id>[/jobs/<n>]` and `circleci.com/<vcs>/<org>/<repo>/<n>`; nil for
    /// anything else.
    public init?(url string: String) {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "app.circleci.com":
            if parts.count >= 2, parts[0] == "workflow", let workflow = uuid(parts[1]) {
                if parts.count >= 4, parts[2] == "job", let job = uuid(parts[3]) {
                    self = .job(id: job)
                } else {
                    self = .workflow(id: workflow, jobNumber: nil)
                }
            } else if parts.count >= 7, parts[0] == "pipelines", parts[5] == "workflows", let workflow = uuid(parts[6]) {
                let number = parts.count >= 9 && parts[7] == "jobs" ? Int(parts[8]) : nil
                self = .workflow(id: workflow, jobNumber: number)
            } else {
                return nil
            }
        case "circleci.com":
            guard parts.count >= 4, let vcs = vcsSlug(parts[0]), let number = Int(parts[3]) else { return nil }
            self = .numbered(project: "\(vcs)/\(parts[1])/\(parts[2])", number: number)
        default:
            return nil
        }
    }
}

/// A CircleCI job, with each of its steps on each of its parallel executions.
public struct CircleCIJob: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// "succeeded", "failed", "canceled" and so on once it has ended; nil before.
    public var outcome: String?
    public var workflowId: String?
    /// Every execution's steps, the first execution's first.
    public var steps: [CircleCIStep]
    public var executionCount: Int

    public init(id: String, name: String, outcome: String?, workflowId: String?, steps: [CircleCIStep], executionCount: Int) {
        self.id = id
        self.name = name
        self.outcome = outcome
        self.workflowId = workflowId
        self.steps = steps
        self.executionCount = executionCount
    }

    public var failedSteps: [CircleCIStep] {
        steps.filter(\.isFailed)
    }

    public var hasEnded: Bool {
        outcome != nil
    }

    /// Its page on CircleCI.
    public var webURL: URL? {
        guard let workflowId else { return nil }
        return URL(string: "https://app.circleci.com/workflow/\(workflowId)/job/\(id)")
    }
}

public struct CircleCIStep: Sendable, Hashable, Identifiable {
    /// Which parallel execution it ran on, from 0.
    public var execution: Int
    /// Its number in the job, which CircleCI numbers its output by.
    public var number: Int
    public var name: String
    /// "succeeded", "failed" and so on once it has ended; nil before.
    public var outcome: String?
    public var exitCode: Int?
    /// What it ran, for a `run` step.
    public var command: String?

    public init(execution: Int, number: Int, name: String, outcome: String?, exitCode: Int?, command: String?) {
        self.execution = execution
        self.number = number
        self.name = name
        self.outcome = outcome
        self.exitCode = exitCode
        self.command = command
    }

    public var id: String { "\(execution)/\(number)" }

    /// Ended other than by succeeding or being passed over.
    public var isFailed: Bool {
        guard let outcome else { return false }
        return !["succeeded", "not_run", "skipped"].contains(outcome)
    }
}

/// A test a job's stored results say failed.
public struct CircleCITestFailure: Sendable, Hashable, Identifiable {
    /// Its place among the job's failures, as names needn't be unique.
    public var id: Int
    /// The suite, file or package it belongs to.
    public var classname: String
    public var name: String
    public var message: String
    /// In seconds.
    public var runTime: Double?

    public init(id: Int, classname: String, name: String, message: String, runTime: Double?) {
        self.id = id
        self.classname = classname
        self.name = name
        self.message = message
        self.runTime = runTime
    }
}

/// A file a job kept.
public struct CircleCIArtifact: Sendable, Hashable, Identifiable {
    public var path: String
    public var url: URL
    public var execution: Int

    public init(path: String, url: URL, execution: Int) {
        self.path = path
        self.url = url
        self.execution = execution
    }

    public var id: String { "\(execution)/\(path)" }
}

private func uuid(_ string: String) -> String? {
    UUID(uuidString: string).map { $0.uuidString.lowercased() }
}

/// The project slug's prefix for a link's version-control segment.
private func vcsSlug(_ segment: String) -> String? {
    switch segment.lowercased() {
    case "gh", "github": "gh"
    case "bb", "bitbucket": "bb"
    default: nil
    }
}
