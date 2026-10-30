import AppKit
import LoupeCore
import LoupeFakeGitHub
import LoupeInbox
import LoupeModel
import SwiftUI

/// The sidebar's row for Terraform Cloud's plans of the PR, under Conversation, while its checks
/// report any runs: what the plans add, destroy and change, summed, and across how many
/// workspaces ("envs").
struct TerraformRow: View {
    @Bindable var tab: PullRequestTab
    @State private var isHovered = false

    static let symbol = "square.stack.3d.up"

    var body: some View {
        let isShown = tab.shownSection == .terraform
        let summary = TerraformPlansSummary(tab.terraformPlans)
        Button { tab.showTerraform() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("Terraform", systemImage: Self.symbol)
                Label {
                    SummaryText(summary: summary, isOnAccent: isShown)
                        .font(.caption)
                        .lineLimit(1)
                } icon: {
                    // Lines the summary up under the title.
                    Image(systemName: Self.symbol).hidden()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "Show Terraform Cloud's plans (⌃5)"))
        .accessibilityAddTraits(isShown ? .isSelected : [])
        .accessibilityIdentifier("terraform-row")
        .foregroundStyle(isShown ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(sidebarRowStyle(isShown: isShown, isHovered: isHovered), in: RoundedRectangle(cornerRadius: 5))
        .onHover { isHovered = $0 }
        // Sits right under the Conversation row, whose own padding spaces them.
        .padding([.horizontal, .bottom], 8)
    }
}

/// "+8 -2 ~1 across 2 envs", then any still planning or failed.
private struct SummaryText: View {
    let summary: TerraformPlansSummary
    let isOnAccent: Bool

    var body: some View {
        let secondary = isOnAccent ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
        HStack(spacing: 4) {
            if summary.planned > 0 {
                CountsText(counts: summary.counts, isOnAccent: isOnAccent)
                Text(verbatim: "across \(summary.planned) \(summary.planned == 1 ? "env" : "envs")")
                    .foregroundStyle(secondary)
            }
            if summary.planning > 0 {
                Text(verbatim: "\(summary.planned > 0 ? "· " : "")\(summary.planning) planning")
                    .foregroundStyle(secondary)
            }
            if summary.failed > 0 {
                Text(verbatim: "\(summary.planned + summary.planning > 0 ? "· " : "")\(summary.failed) failed")
                    .foregroundStyle(isOnAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.diffDanger))
            }
        }
    }
}

/// "+8 -2 ~1": to add, to destroy, to change, coloured as Terraform colours them.
private struct CountsText: View {
    let counts: TerraformPlanCounts
    let isOnAccent: Bool

    var body: some View {
        HStack(spacing: 4) {
            count("+", counts.add, .diffSuccess)
            count("-", counts.destroy, .diffDanger)
            count("~", counts.change, .diffAttention)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "+\(counts.add) -\(counts.destroy) ~\(counts.change)"))
    }

    private func count(_ symbol: String, _ number: Int, _ color: Color) -> some View {
        Text(verbatim: "\(symbol)\(number)")
            .foregroundStyle(isOnAccent ? AnyShapeStyle(.white) : number == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
    }
}

/// Terraform Cloud's plans beside the sidebar: the envs it planned in, each with its counts, and
/// the chosen one's plan as Terraform prints it. Plans are read when first chosen.
struct TerraformPane: View {
    @Bindable var plans: TerraformPlans
    let checks: [TerraformPlanCheck]
    let isShown: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if let host = plans.signedOutHosts.first {
                SignInBanner(host: host) { Task { await plans.retry() } }
                Divider()
            }
            HStack(spacing: 0) {
                envList
                    .frame(width: 260)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform-pane")
        // Listed again whenever the checks change, as when a plan finishes or after a push.
        .task(id: isShown ? checks : nil) {
            if isShown { await plans.show(checks) }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: TerraformRow.symbol)
                .foregroundStyle(.secondary)
            Text("Terraform Cloud")
                .font(.headline)
            SummaryText(summary: TerraformPlansSummary(checks), isOnAccent: false)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let check = plans.selected {
                Button("Open in Terraform Cloud", systemImage: "safari") { openInBrowser(check.url) }
                    .labelStyle(.iconOnly)
                    .help("Open the run in Terraform Cloud in the default browser")
            }
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var envList: some View {
        let showsOrganization = Set(checks.map(\.organization)).count > 1
        return List(selection: Binding(get: { plans.selectedId }, set: { id in Task { await plans.select(id) } })) {
            ForEach(checks) { check in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: showsOrganization ? check.id : check.workspace)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    EnvState(check: check)
                        .font(.caption)
                }
                .padding(.vertical, 2)
                .help(Text(verbatim: check.id))
                .tag(check.id)
            }
        }
        .accessibilityIdentifier("terraform-envs")
    }

    @ViewBuilder
    private var detail: some View {
        if let check = plans.selected {
            PlanView(plans: plans, check: check)
                .id(check.runId)
        } else {
            ContentUnavailableView {
                Label("Choose an environment", systemImage: TerraformRow.symbol)
            } description: {
                Text("Its plan shows here, as Terraform prints it.")
            }
        }
    }
}

/// What an env's check says of its plan, under its name in the list.
private struct EnvState: View {
    let check: TerraformPlanCheck

    var body: some View {
        switch check.state {
        case let .planned(counts?) where !counts.hasChanges:
            Text("No changes").foregroundStyle(.secondary)
        case let .planned(counts?):
            CountsText(counts: counts, isOnAccent: false)
        case .planned(nil):
            Text("Planned").foregroundStyle(.secondary)
        case .planning:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Planning…")
            }
            .foregroundStyle(.secondary)
        case let .failed(description):
            Text(verbatim: description ?? "Failed")
                .foregroundStyle(.diffDanger)
                .lineLimit(1)
        }
    }
}

/// The chosen env's plan: a line saying what it comes to, over the plan as Terraform prints it.
private struct PlanView: View {
    let plans: TerraformPlans
    let check: TerraformPlanCheck

    var body: some View {
        if check.state == .planning {
            ContentUnavailableView {
                Label("Terraform Cloud is still planning", systemImage: "clock")
            } description: {
                Text(verbatim: "\(check.workspace)'s plan shows here once it has finished.")
            } actions: {
                Button("Open in Terraform Cloud") { openInBrowser(check.url) }
            }
        } else {
            switch plans.plan(of: check) {
            case .loading, nil:
                LoadingLabel(title: "Reading the plan from Terraform Cloud…")
            case let .failed(failure):
                ContentUnavailableView {
                    Label(failure.title, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(LocalizedStringKey(failure.message)).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { Task { await plans.retry() } }
                }
            case let .loaded(.planned(plan)):
                VStack(spacing: 0) {
                    header(Text(verbatim: "Plan: \(TerraformPlanText.summary(plan.counts))."))
                    Divider()
                    TerminalTextView(text: TerraformPlanText.render(plan), identity: check.runId, scrollsToEnd: false)
                        .accessibilityIdentifier("terraform-plan")
                }
            case let .loaded(.errored(log)):
                VStack(spacing: 0) {
                    header(Text("The plan errored").foregroundStyle(.diffDanger))
                    Divider()
                    TerminalTextView(text: log.isEmpty ? "Terraform Cloud kept no log of the error." : log, identity: check.runId, scrollsToEnd: false)
                        .accessibilityIdentifier("terraform-plan")
                }
            case let .loaded(.unfinished(status)):
                ContentUnavailableView {
                    Label("No plan to show", systemImage: "questionmark.circle")
                } description: {
                    Text(verbatim: "Terraform Cloud says the run is \(status.replacingOccurrences(of: "_", with: " ")).")
                } actions: {
                    Button("Open in Terraform Cloud") { openInBrowser(check.url) }
                }
            }
        }
    }

    private func header(_ summary: Text) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: check.workspace).font(.headline).lineLimit(1)
            summary.foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Says the plans can't be read until `terraform login` signs in to `host`.
private struct SignInBanner: View {
    let host: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .foregroundStyle(.diffAttention)
            Text(LocalizedStringKey(TerraformCloudRuns.Failure.signedOut(host: host).message))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Try Again", action: retry)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform-sign-in")
    }
}

/// Each tab's Terraform plans, made when first shown and kept while the tab lives, read with
/// `terraform login`'s token, or from the fake Terraform Cloud in a fixture run.
@MainActor
enum TerraformPages {
    private static let pages = NSMapTable<PullRequestTab, TerraformPlans>.weakToStrongObjects()
    private static let client: TerraformCloudRuns = {
        guard let fake = FixtureRun.terraformCloud else { return TerraformCloudRuns.live() }
        return TerraformCloudRuns(token: FakeTerraformCloud.token, transport: transport(to: fake))
    }()

    static func plans(for tab: PullRequestTab) -> TerraformPlans {
        if let plans = pages.object(forKey: tab) { return plans }
        let plans = TerraformPlans(client: client)
        pages.setObject(plans, forKey: tab)
        return plans
    }

    static func existingPlans(for tab: PullRequestTab) -> TerraformPlans? {
        pages.object(forKey: tab)
    }
}

private func transport(to fake: FakeTerraformCloud) -> TerraformCloudRuns.Transport {
    { request in try await fake.send(request) }
}
