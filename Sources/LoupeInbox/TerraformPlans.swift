import Foundation
import LoupeCore
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
    /// Each finished plan's rows, by run, made once it's read.
    private var outlines: [String: TerraformPlanOutline] = [:]
    /// Which resources of each run's plan are expanded and which row the keys act on, kept while
    /// the tab lives so going back to an env finds it as it was left.
    private var folds: [String: Fold] = [:]

    private struct Fold {
        var expanded: Set<String> = []
        var current: String?
    }

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

    /// The plan as rows of resources, once it's read and if it planned.
    public func outline(of check: TerraformPlanCheck) -> TerraformPlanOutline? {
        outlines[check.runId]
    }

    /// The resources expanded in the plan; each starts collapsed.
    public func expanded(in check: TerraformPlanCheck) -> Set<String> {
        folds[check.runId]?.expanded ?? []
    }

    /// The resource whose row the keys act on, if one has been picked.
    public func current(in check: TerraformPlanCheck) -> String? {
        folds[check.runId]?.current
    }

    public func setCurrent(_ id: String?, in check: TerraformPlanCheck) {
        folds[check.runId, default: Fold()].current = id
    }

    public func setExpanded(_ ids: Set<String>, _ isExpanded: Bool, in check: TerraformPlanCheck) {
        if isExpanded {
            folds[check.runId, default: Fold()].expanded.formUnion(ids)
        } else {
            folds[check.runId, default: Fold()].expanded.subtract(ids)
        }
    }

    public func toggle(_ id: String, in check: TerraformPlanCheck) {
        setExpanded([id], !expanded(in: check).contains(id), in: check)
    }

    /// Expands or collapses every resource in the plan.
    public func setAllExpanded(_ isExpanded: Bool, in check: TerraformPlanCheck) {
        guard let outline = outline(of: check) else { return }
        setExpanded(Set(outline.resources.map(\.id)), isExpanded, in: check)
    }

    /// Whether every resource of the plan is expanded, so there's nothing more to expand.
    public func isAllExpanded(in check: TerraformPlanCheck) -> Bool {
        guard let outline = outline(of: check) else { return false }
        return expanded(in: check).isSuperset(of: outline.resources.map(\.id))
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
            let plan = try await client.plan(of: check)
            if case let .planned(planned) = plan { outlines[check.runId] = TerraformPlanOutline(planned) }
            plans[check.runId] = .loaded(plan)
        } catch {
            plans[check.runId] = .failed(error)
        }
    }
}
