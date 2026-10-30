@testable import LoupeFakeGitHub
import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import Testing

@MainActor
struct TerraformPlansTests {
    @Test func aPullRequestsTerraformCloudRunsListTheirEnvsAndEachOnesPlan() async throws {
        let app = try await ConversationApp()
        let terraform = FakeTerraformCloud.fixture()
        let pullRequest = try #require(app.mine.first { $0.repository == "tamarinworks/bedrock" && $0.number == 2193 })
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))

        // Workspaces whose runs weren't triggered link no run and are left out.
        #expect(tab.terraformPlans.map(\.workspace) == ["prod-platform", "stage-platform"])
        let summary = TerraformPlansSummary(tab.terraformPlans)
        #expect(summary.counts == TerraformPlanCounts(add: 16, change: 2, destroy: 2))
        #expect(summary.planned == 2)
        tab.showTerraform()
        #expect(tab.shownSection == .terraform)

        // The envs are listed from the checks; nothing is read until one is chosen.
        let plans = TerraformPlans(client: client(terraform))
        await plans.show(tab.terraformPlans)
        #expect(plans.selected == nil)
        #expect(await terraform.requests.isEmpty)

        await plans.select("tamarinworks/prod-platform")
        let prod = try #require(plans.selected)
        guard case let .loaded(.planned(plan))? = plans.plan(of: prod) else {
            Issue.record("expected prod-platform's plan, got \(String(describing: plans.plan(of: prod)))")
            return
        }
        #expect(plan.counts == prod.counts, "the plan agrees with its check")
        let shown = TerminalText.attributed(TerraformPlanText.render(plan)).string
        #expect(shown.contains("# module.gazette.aws_service_discovery_service.gazette must be replaced"))
        #expect(shown.contains("~ name = \"gazette\" -> \"gazette-http\" # forces replacement"))
        #expect(shown.contains("+ \"servicediscovery:DiscoverInstances\","))
        #expect(shown.contains("Plan: 8 to add, 1 to change, 1 to destroy."))
        // The JSON plan is fetched from where the API redirects, without the token, which the
        // fake would refuse.
        #expect(await terraform.requests == ["/api/v2/runs/run-6G6GOK8hrFoqYv2m", "/api/v2/plans/plan-6G6GOK8hrFoqYv2m/json-output", "/json/run-6G6GOK8hrFoqYv2m"])

        // A finished plan doesn't change, so going back reads nothing again, and the env chosen
        // stays chosen as the checks are listed again.
        await plans.select("tamarinworks/stage-platform")
        await plans.select("tamarinworks/prod-platform")
        await plans.show(tab.terraformPlans)
        #expect(await terraform.requests.count == 6)
        #expect(plans.selectedId == "tamarinworks/prod-platform")

        // Once the checks report no runs there's nothing to show.
        try await app.github.setChecks(of: pullRequest.id, state: "SUCCESS", [.status("ci/circleci: format", "SUCCESS")])
        await app.tabs.lists.refresh()
        #expect(tab.terraformPlans.isEmpty)
        #expect(tab.shownSection == .conversation)
    }

    @Test func aPlansResourcesStartCollapsedAndEachEnvKeepsWhatWasExpanded() async throws {
        let app = try await ConversationApp()
        let pullRequest = try #require(app.mine.first { $0.repository == "tamarinworks/bedrock" && $0.number == 2193 })
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        let plans = TerraformPlans(client: client(FakeTerraformCloud.fixture()))
        await plans.show(tab.terraformPlans)

        await plans.select("tamarinworks/prod-platform")
        let prod = try #require(plans.selected)
        let outline = try #require(plans.outline(of: prod))
        #expect(outline.resources.count == 9)
        #expect(plans.expanded(in: prod).isEmpty)
        let shown = outline.shown(expanded: plans.expanded(in: prod)).text.string
        #expect(shown.contains("-/+ module.gazette.aws_service_discovery_service.gazette must be replaced\n    # forces replacement: name"))
        #expect(!shown.contains("desired_count"))

        plans.toggle("module.gazette.aws_ecs_service.grpc", in: prod)
        plans.setCurrent("module.gazette.aws_ecs_service.grpc", in: prod)
        #expect(outline.shown(expanded: plans.expanded(in: prod)).text.string.contains("+ desired_count   = 3"))

        // Another env starts collapsed; going back finds prod as it was left.
        await plans.select("tamarinworks/stage-platform")
        let stage = try #require(plans.selected)
        #expect(plans.expanded(in: stage).isEmpty)
        plans.setAllExpanded(true, in: stage)
        #expect(plans.isAllExpanded(in: stage))
        await plans.select("tamarinworks/prod-platform")
        #expect(plans.expanded(in: prod) == ["module.gazette.aws_ecs_service.grpc"])
        #expect(plans.current(in: prod) == "module.gazette.aws_ecs_service.grpc")
        #expect(!plans.isAllExpanded(in: prod))
        plans.setAllExpanded(false, in: stage)
        #expect(plans.expanded(in: stage).isEmpty)
    }

    @Test func eachEnvSaysWhereItsPlanHasGot() async throws {
        let app = try await ConversationApp()
        let terraform = FakeTerraformCloud()
        let pullRequest = try #require(app.mine.first { $0.repository == "tamarinworks/bedrock" && $0.number == 2193 })
        try await app.github.setChecks(of: pullRequest.id, state: "PENDING", [
            .status("Terraform Cloud/tamarinworks/edge", "SUCCESS", description: "Terraform plan: 1 to import, 2 to add, 0 to change, 1 to destroy.", url: run("edge", "run-EdgeA1")),
            .status("Terraform Cloud/tamarinworks/quiet", "SUCCESS", description: "Terraform plan has no changes.", url: run("quiet", "run-QuietB2")),
            .status("Terraform Cloud/tamarinworks/busy", "PENDING", description: "Terraform Cloud is planning…", url: "https://app.terraform.io/app/tamarinworks/workspaces/busy/runs/run-BusyC3"),
            .status("Terraform Cloud/tamarinworks/broken", "ERROR", description: "Terraform plan errored.", url: run("broken", "run-BrokenD4")),
            .status("Terraform Cloud/tamarinworks/untouched", "SUCCESS", description: "Run not triggered: Terraform working directories did not change."),
            .status("ci/circleci: build", "SUCCESS", url: "https://circleci.com/gh/tamarinworks/bedrock/1"),
        ])
        await app.tabs.lists.refresh()
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))

        #expect(tab.terraformPlans.map(\.workspace) == ["edge", "quiet", "busy", "broken"])
        #expect(tab.terraformPlans.map(\.state) == [
            .planned(TerraformPlanCounts(add: 2, change: 0, destroy: 1, import: 1)),
            .planned(.zero),
            .planning,
            .failed("Terraform plan errored."),
        ])
        let summary = TerraformPlansSummary(tab.terraformPlans)
        #expect(summary.counts == TerraformPlanCounts(add: 2, change: 0, destroy: 1, import: 1))
        #expect(summary.planned == 2)
        #expect(summary.planning == 1)
        #expect(summary.failed == 1)

        // A run still planning has nothing to read yet.
        let plans = TerraformPlans(client: client(terraform))
        await plans.show(tab.terraformPlans)
        await plans.select("tamarinworks/busy")
        #expect(plans.plan(of: try #require(plans.selected)) == nil)
        #expect(await terraform.requests.isEmpty)

        // An errored plan shows its log's errors as Terraform prints them.
        await terraform.add(FakeTerraformCloud.Run(id: "run-BrokenD4", organization: "tamarinworks", workspace: "broken", status: "errored", planStatus: "errored", log: erroredLog))
        await plans.select("tamarinworks/broken")
        let broken = try #require(plans.selected)
        guard case let .loaded(.errored(log))? = plans.plan(of: broken) else {
            Issue.record("expected the errored plan's log, got \(String(describing: plans.plan(of: broken)))")
            return
        }
        let shown = TerminalText.attributed(log).string
        #expect(shown.contains("│ Error: Unsupported argument"))
        #expect(shown.contains("│   on main.tf line 12, in resource \"aws_s3_bucket\" \"exports\":"))
        #expect(shown.contains("│   12:   acceleration = true"))
        #expect(shown.contains("│ An argument named \"acceleration\" is not expected here."))
        #expect(!shown.contains("Refreshing state"))
    }

    @Test func withoutATokenItSaysToRunTerraformLogin() async throws {
        let terraform = FakeTerraformCloud.fixture()
        let directory = FileManager.default.temporaryDirectory.appending(path: "loupe-terraform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = directory.appending(path: "credentials.tfrc.json")
        let checks = [CheckContext(name: "Terraform Cloud/tamarinworks/prod-platform", status: .success, description: "Terraform plan: 8 to add, 1 to change, 1 to destroy.", url: run("prod-platform", "run-6G6GOK8hrFoqYv2m"))].terraformPlans
        let plans = TerraformPlans(client: TerraformCloudRuns(environment: [:], credentials: credentials) { try await terraform.send($0) })

        await plans.show(checks)
        #expect(plans.signedOutHosts == ["app.terraform.io"])
        await plans.select("tamarinworks/prod-platform")
        let check = try #require(plans.selected)
        guard case let .failed(failure)? = plans.plan(of: check) else {
            Issue.record("expected no token, got \(String(describing: plans.plan(of: check)))")
            return
        }
        #expect(failure == .signedOut(host: "app.terraform.io"))
        #expect(failure.message.contains("`terraform login`"))
        #expect(await terraform.requests.isEmpty, "nothing is asked without a token")

        // `terraform login` writes the file; trying again reads it.
        try Data(#"{"credentials":{"app.terraform.io":{"token":"\#(FakeTerraformCloud.token)"}}}"#.utf8).write(to: credentials)
        await plans.retry()
        #expect(plans.signedOutHosts.isEmpty)
        guard case .loaded(.planned)? = plans.plan(of: check) else {
            Issue.record("expected the plan once signed in, got \(String(describing: plans.plan(of: check)))")
            return
        }

        // A token Terraform Cloud turns down says to sign in again.
        let turnedDown = TerraformPlans(client: TerraformCloudRuns(environment: ["TF_TOKEN_app_terraform_io": "expired"], credentials: credentials) { try await terraform.send($0) })
        await turnedDown.show(checks)
        await turnedDown.select("tamarinworks/prod-platform")
        guard case .failed(.refused(host: "app.terraform.io"))? = turnedDown.plan(of: check) else {
            Issue.record("expected the token turned down, got \(String(describing: turnedDown.plan(of: check)))")
            return
        }
    }
}

private func client(_ terraform: FakeTerraformCloud) -> TerraformCloudRuns {
    TerraformCloudRuns(token: FakeTerraformCloud.token) { try await terraform.send($0) }
}

private func run(_ workspace: String, _ id: String) -> String {
    "https://app.terraform.io/app/tamarinworks/\(workspace)/runs/\(id)"
}

/// A structured plan log, as Terraform Cloud keeps one, of a plan that errored.
private let erroredLog = """
Terraform v1.10.5
on linux_amd64
Initializing plugins and modules...
{"@level":"info","@message":"Terraform 1.10.5","@module":"terraform.ui","type":"version","terraform":"1.10.5","ui":"1.2"}
{"@level":"info","@message":"aws_s3_bucket.reports: Refreshing state... [id=tamarin-reports]","@module":"terraform.ui","type":"refresh_start"}
{"@level":"error","@message":"Error: Unsupported argument","@module":"terraform.ui","type":"diagnostic","diagnostic":{"severity":"error","summary":"Unsupported argument","detail":"An argument named \\"acceleration\\" is not expected here.","range":{"filename":"main.tf","start":{"line":12,"column":3,"byte":220},"end":{"line":12,"column":15,"byte":232}},"snippet":{"context":"resource \\"aws_s3_bucket\\" \\"exports\\"","code":"  acceleration = true","start_line":12,"highlight_start_offset":2,"highlight_end_offset":14,"values":[]}}}
"""
