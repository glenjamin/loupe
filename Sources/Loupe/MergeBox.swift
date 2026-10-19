import LoupeInbox
import LoupeModel
import SwiftUI

/// GitHub's merge box in miniature, on the viewer's own open PRs: a Merge button, green when
/// it can be merged and red when it can't, with the first reason why beneath it, or on a draft
/// a "Ready for review" button in its place. Only merge commits are made. Merging asks first
/// and names the branches; leaving draft doesn't, as GitHub lets it be undone. GitHub's refusal
/// of either is shown by `MergeErrorLabel`.
struct MergeBox: View {
    let tab: PullRequestTab
    let readiness: MergeReadiness
    @State private var confirming = false

    var body: some View {
        let pullRequest = tab.pullRequest
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                if tab.isMerging {
                    ProgressView()
                        .controlSize(.small)
                }
                if readiness == .draft {
                    readyForReviewButton
                } else {
                    mergeButton(pullRequest)
                }
            }
            .fixedSize()
            reason
        }
        .alert(Text(verbatim: "Merge \(pullRequest.headRefName) into \(pullRequest.baseRefName)?"), isPresented: $confirming) {
            Button("Merge") { Task { await tab.merge() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "This adds a merge commit to \(pullRequest.baseRefName).")
        }
    }

    /// A disabled button loses its tint, so the reason carries the red.
    @ViewBuilder private var reason: some View {
        if case let .blocked(blocker) = readiness {
            Text(blocker.description)
                .font(.caption)
                .foregroundStyle(.diffDanger)
                .fixedSize()
        }
    }

    private var readyForReviewButton: some View {
        Button("Ready for review", systemImage: "checkmark.circle") { Task { await tab.markReadyForReview() } }
            .buttonStyle(.borderedProminent)
            .disabled(tab.isMerging)
            .help("Mark this PR ready for review on GitHub")
    }

    private func mergeButton(_ pullRequest: PullRequestSummary) -> some View {
        Button("Merge", systemImage: "arrow.triangle.merge") { confirming = true }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(readiness != .ready || tab.isMerging)
            .help(help(pullRequest))
    }

    /// Green to go, red when blocked, and the plain disabled button while GitHub works it out.
    private var tint: Color? {
        switch readiness {
        case .ready: .green
        case .blocked: .red
        case .checking, .draft: nil
        }
    }

    private func help(_ pullRequest: PullRequestSummary) -> String {
        switch readiness {
        case .ready: "Merge \(pullRequest.headRefName) into \(pullRequest.baseRefName) with a merge commit"
        case let .blocked(blocker): "Can't merge: \(blocker.description)"
        case .checking, .draft: "GitHub is still working out whether this can be merged"
        }
    }
}

/// In the merge button's place once a PR is merged or closed: what happened, in the state
/// badge's colour, and when beneath it, where the button's reason sits.
struct OutcomeLabel: View {
    let outcome: PullRequestOutcome

    var body: some View {
        VStack(spacing: 2) {
            Text(outcome.title)
                .font(.headline)
                .foregroundStyle(tint)
            TimelineView(.everyMinute) { context in
                if let when = outcome.when(now: context.date) {
                    Text(verbatim: when)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize()
        .help(outcome.help())
    }

    private var tint: Color {
        switch outcome.kind {
        case .merged: .purple
        case .closed: .diffDanger
        }
    }
}

/// In the merge button's place on someone else's open PR: the viewer's own approval or request
/// for changes, with when and whether the PR has changed since beneath it, where the button's
/// reason sits. Resting on it says which commit it was on and what's changed.
struct ViewerVerdictLabel: View {
    let verdict: ViewerVerdict

    var body: some View {
        VStack(spacing: 2) {
            Label(verdict.title, systemImage: verdict.symbol)
                .font(.headline)
                .foregroundStyle(verdict.tint)
            TimelineView(.everyMinute) { context in
                caption(now: context.date)
                    .font(.caption)
            }
        }
        .fixedSize()
        .background(HoverPopoverAnchor(content: HoverHelp(verdict: verdict)))
    }

    /// When, then how it's moved on since, which stands out once there's something new.
    private func caption(now: Date) -> Text {
        let when = verdict.submittedAt.map { Text(verbatim: $0.recentOrDated(now: now)).foregroundStyle(.secondary) }
        let since = verdict.since.map { since in
            Text(verbatim: since.description).foregroundStyle(since == .unchanged ? .secondary : Color.diffAttention)
        }
        switch (when, since) {
        case let (when?, since?): return when + Text(verbatim: " · ").foregroundStyle(.secondary) + since
        case let (when?, nil): return when
        case let (nil, since?): return since
        case (nil, nil): return Text(verbatim: "")
        }
    }
}

/// GitHub's refusal of a merge or of leaving draft, under the button, wrapping within the
/// merge section.
struct MergeErrorLabel: View {
    let error: String

    var body: some View {
        Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.diffDanger)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
    }
}

extension HoverHelp {
    /// Which commit the viewer's verdict was on, when, and what's happened since.
    init(verdict: ViewerVerdict) {
        let on = [
            verdict.commitOid.map { "On \($0.prefix(7))" },
            verdict.submittedAt.map { $0.formatted(date: .complete, time: .shortened) },
        ].compactMap(\.self).joined(separator: ", ")
        let since = switch verdict.since {
        case .unchanged: "Nothing has been pushed since: the PR is as you saw it."
        case .commits(1): "1 commit has been pushed on top since. \"Since your last review\" in the commit picker shows it."
        case let .commits(count): "\(count) commits have been pushed on top since. \"Since your last review\" in the commit picker shows them."
        case .changed: "The branch has changed since. \"Since your last review\" in the commit picker shows what's new."
        case nil: ""
        }
        self.init(title: "\(verdict.title) this", detail: [on.isEmpty ? "" : "\(on).", since].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

extension ViewerVerdict {
    var title: String {
        state == .approved ? "You approved" : "You requested changes"
    }

    var symbol: String {
        state == .approved ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    var tint: Color {
        state == .approved ? .diffSuccess : .diffDanger
    }

    /// For a tooltip: what, when and whether it's changed since, e.g. "You approved this 2 days
    /// ago, with no changes since".
    var summary: String {
        let when = submittedAt.map { " \($0.recentOrDated())" } ?? ""
        let since = switch since {
        case .unchanged: ", with no changes since"
        case .commits, .changed: ", and it's changed since"
        case nil: ""
        }
        return "\(title) this\(when)\(since)"
    }
}

extension ViewerVerdict.Since: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unchanged: "no changes since"
        case .commits(1): "1 commit since"
        case let .commits(count): "\(count) commits since"
        case .changed: "changed since"
        }
    }
}
