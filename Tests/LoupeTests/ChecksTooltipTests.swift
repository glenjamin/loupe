import LoupeModel
import Testing

struct ChecksTooltipTests {
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
        #expect(checks.tooltip?.split(separator: "\n").first.map(String.init) == summary)
    }

    @Test func listsNothingWithoutChecks() {
        #expect([CheckContext]().tooltip == nil)
    }
}
