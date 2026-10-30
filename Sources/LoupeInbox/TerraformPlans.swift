import Foundation
import LoupeModel

/// What Terraform Cloud planned for a PR, for its Terraform pane: each workspace ("env") its
/// checks report a run in, and for the one chosen, that run's plan, read when first chosen and
/// kept.
@Observable
@MainActor
public final class TerraformPlans {
    public enum Loading: Sendable {
        case loading
        case loaded(TerraformRunPlan)
        case failed(TerraformCloudRuns.Failure)
    }

    /// The checks the envs are listed from.
    public private(set) var checks: [TerraformPlanCheck] = []
    public private(set) var selectedId: TerraformPlanCheck.ID?
    /// The hosts among the checks' that `terraform login` hasn't signed in to, so no plan of
    /// theirs can be read.
    public private(set) var signedOutHosts: [String] = []
    /// By run.
    private var plans: [String: Loading] = [:]

    private let client: TerraformCloudRuns

    public init(client: TerraformCloudRuns) {
        self.client = client
    }

    public var selected: TerraformPlanCheck? {
        checks.first { $0.id == selectedId }
    }

    public func plan(of check: TerraformPlanCheck) -> Loading? {
        plans[check.runId]
    }

    /// Lists the envs `checks` report, keeping the one chosen if it's still among them, and
    /// reads its plan if its run is new.
    public func show(_ checks: [TerraformPlanCheck]) async {
        self.checks = checks
        signedOutHosts = Array(Set(checks.map(\.host))).sorted().filter { !client.hasToken(for: $0) }
        if selected == nil { selectedId = nil }
        if let selected { await load(selected) }
    }

    public func select(_ id: TerraformPlanCheck.ID?) async {
        selectedId = id
        if let selected { await load(selected) }
    }

    /// Asks again for whatever couldn't be read, as after `terraform login`.
    public func retry() async {
        plans = plans.filter { if case .failed = $0.value { false } else { true } }
        await show(checks)
    }

    private func load(_ check: TerraformPlanCheck) async {
        // A run still planning has nothing to read; its check says when it's done. One read
        // before it had finished is read again.
        guard check.state != .planning else { return }
        switch plans[check.runId] {
        case nil, .loaded(.unfinished)?: break
        default: return
        }
        plans[check.runId] = .loading
        do {
            plans[check.runId] = .loaded(try await client.plan(of: check))
        } catch {
            plans[check.runId] = .failed(error)
        }
    }
}
