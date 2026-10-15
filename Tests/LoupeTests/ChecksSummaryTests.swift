import LoupeModel
import Testing

struct ChecksSummaryTests {
    @Test(arguments: [
        ([CheckStatus.success, .success, .success], "All 3 checks passed"),
        ([.success], "1 check passed"),
        ([.pending, .pending], "2 checks pending"),
        ([.success, .pending, .success], "1 of 3 checks pending"),
        ([.success, .neutral, .success], "2 of 3 checks passed, 1 skipped"),
        ([.failure], "1 of 1 check failed"),
        ([.pending, .failure, .success], "1 of 3 checks failed"),
    ])
    func summarisesHowTheChecksWent(statuses: [CheckStatus], summary: String) {
        let checks = statuses.enumerated().map { CheckContext(name: "check \($0.offset)", status: $0.element, description: nil, url: nil) }
        #expect(checks.summary == summary)
    }

    @Test func listsFailingThenPendingThenTheRestInTheirOrder() {
        let checks = [
            ("lint", CheckStatus.success), ("build", .pending), ("coverage", .failure),
            ("deploy", .neutral), ("test", .pending), ("patch", .failure),
        ].map { CheckContext(name: $0.0, status: $0.1, description: nil, url: nil) }
        #expect(checks.failingFirst.map(\.name) == ["coverage", "patch", "build", "test", "lint", "deploy"])
    }

    @Test func namesTheFailedChecksWithoutTheirIntegrationsPrefix() {
        let checks = [
            ("ci/circleci: build", CheckStatus.failure), ("ci/circleci: lint", .success),
            ("Terraform Cloud/tamarinworks/sandbox", .failure), ("UI Tests", .failure),
            ("ci/circleci: test-ruby25", .pending), ("Add issues and PRs to project ", .failure),
        ].map { CheckContext(name: $0.0, status: $0.1, description: nil, url: nil) }
        #expect(checks.failedCheckNames == ["build", "tamarinworks/sandbox", "UI Tests", "Add issues and PRs to project"])
    }

    @Test func leavesOutCodecovsFailures() {
        let checks = [
            ("codecov/patch", CheckStatus.failure), ("Codecov/project", .failure), ("ci/circleci: build", .success),
        ].map { CheckContext(name: $0.0, status: $0.1, description: nil, url: nil) }
        #expect(checks.failedCheckNames.isEmpty)
    }

    @Test func summarisesNothingWithoutChecks() {
        #expect([CheckContext]().summary == nil)
    }
}
