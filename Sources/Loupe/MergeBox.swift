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
