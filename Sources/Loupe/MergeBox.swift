import LoupeInbox
import LoupeModel
import SwiftUI

/// GitHub's merge box in miniature, on the viewer's own open PRs: a Merge button, green when
/// it can be merged and red when it can't, with the first reason why beneath it, or on a draft
/// a "Ready for review" button in its place. Only merge commits are made. Merging asks first
/// and names the branches; leaving draft doesn't, as GitHub lets it be undone. GitHub's refusal
/// of either is shown by `MergeErrorLabel`.
struct MergeBox: View {
    @Bindable var tab: PullRequestTab
    let readiness: MergeReadiness

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
            if tab.isMerging, readiness != .draft {
                Text("Merging…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                reason
            }
            // Any other PR stacked below gives the reason itself.
            if readiness == .draft, let bottom = tab.mergeFirst {
                MergeFirstLabel(parent: bottom)
            }
        }
        .alert(Text(verbatim: "Merge \(pullRequest.headRefName) into \(pullRequest.baseRefName)?"), isPresented: $tab.isConfirmingMerge) {
            Button("Merge") { Task { await tab.merge() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "This adds a merge commit to \(pullRequest.baseRefName).")
        }
    }

    /// A disabled button loses its tint, so the reason carries the red. Resting on conflicts
    /// lists the conflicting files, as the Conflicts badge does.
    @ViewBuilder private var reason: some View {
        if case let .blocked(blocker) = readiness {
            let text = Text(blocker.description)
                .font(.caption)
                .foregroundStyle(.diffDanger)
                .fixedSize()
            if case .conflicts = blocker {
                text.background(HoverPopoverAnchor(content: ConflictsPopoverContent(tab: tab)))
            } else {
                text
            }
        }
    }

    private var readyForReviewButton: some View {
        Button("Ready for review", systemImage: "checkmark.circle") { Task { await tab.markReadyForReview() } }
            .buttonStyle(.borderedProminent)
            .disabled(tab.isMerging)
            .help("Mark this PR ready for review on GitHub")
    }

    private func mergeButton(_ pullRequest: PullRequestSummary) -> some View {
        Button("Merge", systemImage: "arrow.triangle.merge") { tab.isConfirmingMerge = true }
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
        case .ready: "Merge \(pullRequest.headRefName) into \(pullRequest.baseRefName) with a merge commit (⇧⌘M)"
        case let .blocked(.stacked(number, cascades: true)):
            "Merging this would merge #\(number) and any others below it in the stack too, so a stack is merged from the bottom, one PR at a time. Merge #\(number) first."
        case let .blocked(.stacked(number, cascades: false)):
            "This is based on \(pullRequest.baseRefName), a branch of the stack below it, so merging it would merge it into that branch. Merge #\(number) first."
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
            EveryMinute { now in
                if let when = outcome.when(now: now) {
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
            EveryMinute { now in
                caption(now: now)
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
/// merge section to its full length, with any link in it clickable.
struct MergeErrorLabel: View {
    let error: String

    var body: some View {
        Label {
            Text(linked(error))
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.diffDanger)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
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

/// `text` with each web address in it made a link, as GitHub's messages name its docs.
private func linked(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
    for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let url = match.url, let range = Range(match.range, in: text),
              let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
        attributed[lower..<upper].link = url
    }
    return attributed
}
