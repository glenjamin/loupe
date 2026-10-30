import Foundation

/// A Terraform Cloud run a check reports on: the workspace ("env") it planned in, its link and
/// what the check says of its plan. Terraform Cloud reports each workspace's speculative plan on
/// a PR's head commit as a commit status, `Terraform Cloud/<org>/<workspace>`, linking the run.
public struct TerraformPlanCheck: Sendable, Hashable, Identifiable {
    public var organization: String
    public var workspace: String
    public var runId: String
    /// The run's page in Terraform Cloud.
    public var url: URL
    public var state: State

    public init(organization: String, workspace: String, runId: String, url: URL, state: State) {
        self.organization = organization
        self.workspace = workspace
        self.runId = runId
        self.url = url
        self.state = state
    }

    public var id: String { "\(organization)/\(workspace)" }

    /// The host the run's API is on: app.terraform.io, or a Terraform Enterprise's own.
    public var host: String { url.host() ?? "app.terraform.io" }

    public enum State: Sendable, Hashable {
        /// Planned, with the counts the check gives, which "has no changes" gives as zero; nil
        /// when its words carry none.
        case planned(TerraformPlanCounts?)
        case planning
        /// Errored or was cancelled, in the check's words.
        case failed(String?)
    }

    public var counts: TerraformPlanCounts? {
        if case let .planned(counts) = state { counts } else { nil }
    }
}

/// How many resources a plan adds, changes, destroys and imports, as Terraform's "Plan:" line
/// counts them: a replacement is one to add and one to destroy.
public struct TerraformPlanCounts: Sendable, Hashable {
    public var add: Int
    public var change: Int
    public var destroy: Int
    public var `import`: Int

    public init(add: Int, change: Int, destroy: Int, import: Int = 0) {
        self.add = add
        self.change = change
        self.destroy = destroy
        self.import = `import`
    }

    public static let zero = TerraformPlanCounts(add: 0, change: 0, destroy: 0)

    public var hasChanges: Bool { add + change + destroy + `import` > 0 }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(add: lhs.add + rhs.add, change: lhs.change + rhs.change, destroy: lhs.destroy + rhs.destroy, import: lhs.import + rhs.import)
    }

    /// Reads "Terraform plan: 1 to import, 8 to add, 1 to change, 1 to destroy." and "Terraform
    /// plan has no changes."; nil for words with neither.
    public init?(checkDescription text: String) {
        let lowered = text.lowercased()
        let numbers = ["add", "change", "destroy", "import"].map { count(of: $0, in: lowered) }
        if numbers.contains(where: { $0 != nil }) {
            self.init(add: numbers[0] ?? 0, change: numbers[1] ?? 0, destroy: numbers[2] ?? 0, import: numbers[3] ?? 0)
        } else if lowered.contains("no changes") {
            self = .zero
        } else {
            return nil
        }
    }
}

/// The PR's plans taken together, for the sidebar's Terraform row.
public struct TerraformPlansSummary: Sendable, Hashable {
    /// Summed over the plans whose checks give counts.
    public var counts: TerraformPlanCounts
    /// How many workspaces have a plan.
    public var planned: Int
    public var planning: Int
    public var failed: Int

    public init(_ checks: [TerraformPlanCheck]) {
        counts = checks.compactMap(\.counts).reduce(.zero, +)
        planned = checks.filter { if case .planned = $0.state { true } else { false } }.count
        planning = checks.filter { $0.state == .planning }.count
        failed = checks.filter { if case .failed = $0.state { true } else { false } }.count
    }
}

extension [CheckContext] {
    /// The checks reporting Terraform Cloud runs, in GitHub's order. A workspace whose run wasn't
    /// triggered, as its working directory didn't change, links no run and is left out.
    public var terraformPlans: [TerraformPlanCheck] {
        compactMap { context in
            guard context.name.hasPrefix("Terraform"), let link = context.url.flatMap(TerraformRunLink.init(url:)) else { return nil }
            let state: TerraformPlanCheck.State = switch context.status {
            case .pending: .planning
            case .failure, .neutral: .failed(context.description)
            case .success: .planned(context.description.flatMap(TerraformPlanCounts.init(checkDescription:)))
            }
            return TerraformPlanCheck(organization: link.organization, workspace: link.workspace, runId: link.runId, url: link.url, state: state)
        }
    }
}

/// A run's page: `https://<host>/app/<org>/<workspace>/runs/<run id>`, or with
/// `/workspaces/<workspace>` as Terraform Cloud's newer links have it.
struct TerraformRunLink {
    let organization: String
    let workspace: String
    let runId: String
    let url: URL

    init?(url string: String) {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, parts[0] == "app", let runs = parts.lastIndex(of: "runs"), runs >= 3, runs + 1 < parts.count,
              parts[runs + 1].hasPrefix("run-") else { return nil }
        organization = parts[1]
        workspace = parts[runs - 1]
        runId = parts[runs + 1]
        self.url = url
    }
}

/// The number before "to `verb`", as in "8 to add".
private func count(of verb: String, in text: String) -> Int? {
    guard let range = text.range(of: " to \(verb)") else { return nil }
    let digits = text[..<range.lowerBound].reversed().prefix { $0.isNumber }
    return digits.isEmpty ? nil : Int(String(digits.reversed()))
}
