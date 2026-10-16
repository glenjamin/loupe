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

    @Test func listsFailingThenPendingThenToleratedFailuresThenTheRestInTheirOrder() {
        let checks = [
            ("lint", CheckStatus.success, nil), ("codecov/project", .failure, "96.01% (-2.22%) compared to 8b4635f"),
            ("build", .pending, nil), ("coverage", .failure, nil), ("deploy", .neutral, nil),
            ("test", .pending, nil), ("patch", .failure, nil),
        ].map { CheckContext(name: $0.0, status: $0.1, description: $0.2, url: nil) }
        #expect(checks.failingFirst.map(\.name) == ["coverage", "patch", "build", "test", "codecov/project", "lint", "deploy"])
    }

    @Test func doesNotCountToleratedCoverageFailuresAsFailed() {
        let checks = [
            ("ci/circleci: build", CheckStatus.success, nil), ("ci/circleci: lint", .neutral, nil),
            ("codecov/patch", .failure, "76.92% of diff hit (target 98.23%)"),
            ("Codecov/project", .failure, "96.01% (-2.22%) compared to 8b4635f"),
        ].map { CheckContext(name: $0.0, status: $0.1, description: $0.2, url: nil) }
        #expect(checks.summary == "1 of 4 checks passed, 1 skipped, 2 coverage failures ignored")
        #expect(Array(checks.prefix(3)).summary == "1 of 3 checks passed, 1 skipped, 1 coverage failure ignored")
    }

    @Test func namesTheFailedChecksWithoutTheirIntegrationsPrefix() {
        let checks = [
            ("ci/circleci: build", CheckStatus.failure), ("ci/circleci: lint", .success),
            ("Terraform Cloud/tamarinworks/sandbox", .failure), ("UI Tests", .failure),
            ("ci/circleci: test-ruby25", .pending), ("Add issues and PRs to project ", .failure),
        ].map { CheckContext(name: $0.0, status: $0.1, description: nil, url: nil) }
        #expect(checks.failedCheckNames == ["build", "tamarinworks/sandbox", "UI Tests", "Add issues and PRs to project"])
    }

    @Test func leavesOutToleratedFailuresButNamesAPoorlyCoveredDiff() {
        let checks = [
            ("codecov/patch", CheckStatus.failure, Optional("65.00% of diff hit (target 98.23%)")),
            ("Codecov/project", .failure, "96.01% (-2.22%) compared to 8b4635f"), ("ci/circleci: build", .success, nil),
        ].map { CheckContext(name: $0.0, status: $0.1, description: $0.2, url: nil) }
        #expect(checks.failedCheckNames == ["patch"])
    }

    @Test func summarisesNothingWithoutChecks() {
        #expect([CheckContext]().summary == nil)
    }
}
