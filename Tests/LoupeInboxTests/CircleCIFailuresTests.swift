@testable import LoupeFakeGitHub
import Foundation
import LoupeInbox
import LoupeModel
import Testing

@MainActor
struct CircleCIFailuresTests {
    @Test func aPullRequestsFailedCircleCIJobsShowTheirFailedStepsTestsAndArtifacts() async throws {
        let app = try await ConversationApp()
        let circleCI = FakeCircleCI.fixture()
        let pullRequest = try #require(app.mine.first { $0.number == 14268 })
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))

        #expect(tab.failedCircleCIChecks.map(\.name) == ["playwright", "typecheck"])
        tab.showCircleCI()
        #expect(tab.shownSection == .circleCI)

        let failures = CircleCIFailures(client: client(circleCI))
        await failures.show(tab.failedCircleCIChecks)
        #expect(failures.jobs.value?.map(\.name) == ["playwright", "typecheck"])

        // The first job is shown, at its first failed step: each parallel run's is listed.
        let playwright = try #require(failures.selectedJob)
        #expect(playwright.name == "playwright")
        #expect(playwright.failedSteps.map(\.id) == ["0/106", "1/106"])
        let step = try #require(failures.selectedStep(in: playwright))
        #expect(failures.output(of: step, in: playwright)?.value?.contains("shard 1 of 2") == true)
        #expect(failures.tests[playwright.id]?.value?.map(\.name) == ["a board keeps its layout after a reload", "a shared link opens read-only"], "only the failures")
        #expect(failures.tests[playwright.id]?.value?.first?.message.contains("Timeout 40000ms exceeded") == true)
        #expect(failures.artifacts[playwright.id]?.value?.map(\.path) == ["playwright-report/index.html", "playwright-report/data/trace.zip", "test-results/boards-a-board-keeps-its-layout/test-failed-1.png"])

        let second = playwright.failedSteps[1]
        await failures.select(step: second, in: playwright)
        #expect(failures.output(of: second, in: playwright)?.value?.contains("shard 2 of 2") == true)

        // A job that stored no tests or artifacts has none, rather than failing to say.
        let typecheck = try #require(failures.jobs.value?.last)
        await failures.select(job: typecheck.id)
        let typecheckStep = try #require(failures.selectedStep(in: typecheck))
        #expect(typecheckStep.exitCode == 2)
        #expect(failures.output(of: typecheckStep, in: typecheck)?.value?.contains("error TS2322") == true)
        #expect(failures.tests[typecheck.id]?.value == [])
        #expect(failures.artifacts[typecheck.id]?.value == [])

        // Ended jobs don't change, so going back reads nothing again.
        let asked = await circleCI.requests.count
        await failures.select(job: playwright.id)
        await failures.show(tab.failedCircleCIChecks)
        await failures.select(step: second, in: playwright)
        #expect(await circleCI.requests.count == asked)
        #expect(failures.selectedJob?.id == playwright.id)

        // Once the checks pass there's nothing to show.
        try await app.github.setChecks(of: pullRequest.id, state: "SUCCESS", [.status("ci/circleci: playwright", "SUCCESS")])
        await app.tabs.lists.refresh()
        #expect(tab.failedCircleCIChecks.isEmpty)
        #expect(tab.shownSection == .conversation)
    }

    @Test func checksLinkingAWorkflowOrAJobByNumberLeadToTheirJobs() async throws {
        let workflow = "8d0e2a52-3c1f-4a7b-9e1d-2f6b8c4a1e90"
        // A page of one job, so the workflow's jobs take several.
        let circleCI = FakeCircleCI(pageSize: 1)
        for (number, name, outcome) in [(301, "build", "succeeded"), (302, "lint", "failed"), (303, "test", "failed"), (304, "e2e", "failed")] {
            await circleCI.add(job("job-\(number)", number: number, name: name, workflow: workflow, outcome: outcome))
        }
        let checks: [CheckContext] = [
            CheckContext(name: "ci/circleci: lint", status: .failure, description: nil, url: "https://circleci.com/gh/tamarinworks/porter/302"),
            CheckContext(name: "ci/circleci: test", status: .failure, description: nil, url: "https://app.circleci.com/pipelines/github/tamarinworks/porter/88/workflows/\(workflow)/jobs/303"),
            // A check run for the whole workflow: each of its failed jobs, the others once only.
            CheckContext(name: "porter-workflow", status: .failure, description: nil, url: "https://app.circleci.com/workflow/\(workflow)?utm_source=github-checks-link"),
            CheckContext(name: "ci/circleci: build", status: .success, description: nil, url: "https://circleci.com/gh/tamarinworks/porter/301"),
        ]

        let jobs = try await client(circleCI).failedJobs(of: checks.failedCircleCIChecks)

        #expect(jobs.map(\.name) == ["lint", "test", "e2e"])
    }

    @Test func withTheCLISignedOutOrTurnedDownItSaysToSignIn() async throws {
        let circleCI = FakeCircleCI.fixture()
        let checks = [FailedCircleCICheck(name: "typecheck", link: .job(id: "c0555525-bd97-b6dd-530a-7ffc511c2525"))]

        let signedOut = CircleCIFailures(client: CircleCIJobs(environment: ["LOUPE_CIRCLECI_TOKEN_COMMAND": "/nonexistent/circleci-token"], transport: { try await circleCI.send($0) }))
        await signedOut.show(checks)
        guard case .failed(.signedOut) = signedOut.jobs else {
            Issue.record("expected no token, got \(signedOut.jobs)")
            return
        }
        #expect(await circleCI.requests.isEmpty, "nothing is asked without a token")

        let turnedDown = CircleCIFailures(client: CircleCIJobs(token: "expired", transport: { try await circleCI.send($0) }))
        await turnedDown.show(checks)
        guard case .failed(.refused) = turnedDown.jobs else {
            Issue.record("expected the token turned down, got \(turnedDown.jobs)")
            return
        }
    }
}

private func client(_ circleCI: FakeCircleCI) -> CircleCIJobs {
    CircleCIJobs(token: FakeCircleCI.token) { try await circleCI.send($0) }
}

private func job(_ id: String, number: Int, name: String, workflow: String, outcome: String) -> FakeCircleCI.Job {
    let step = FakeCircleCI.Step(number: 101, name: name, outcome: outcome, stdout: "\(name) \(outcome)\n")
    return FakeCircleCI.Job(id: id, number: number, name: name, project: "gh/tamarinworks/porter", workflow: workflow, outcome: outcome, executions: [[step]])
}
