import LoupeInbox
import LoupeModel
import SwiftUI

/// GitHub's merge box in miniature, on the viewer's own open PRs: a Merge button, green when
/// it can be merged and red when it can't, with the first reason why beneath it. Only merge
/// commits are made. Merging asks first, names the branches, and shows GitHub's refusal here.
struct MergeBox: View {
    let tab: PullRequestTab
    let readiness: MergeReadiness
    @State private var confirming = false

    var body: some View {
        let pullRequest = tab.pullRequest
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if tab.isMerging {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Merge", systemImage: "arrow.triangle.merge") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .disabled(readiness != .ready || tab.isMerging)
                    .help(help(pullRequest))
            }
            // A disabled button loses its tint, so the reason carries the red.
            if case let .blocked(blocker) = readiness {
                Label(blocker.description, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.diffDanger)
            }
            if let error = tab.mergeError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.diffDanger)
                    .lineLimit(3)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .alert(Text(verbatim: "Merge \(pullRequest.headRefName) into \(pullRequest.baseRefName)?"), isPresented: $confirming) {
            Button("Merge") { Task { await tab.merge() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "This adds a merge commit to \(pullRequest.baseRefName).")
        }
    }

    /// Green to go, red when blocked, and the plain disabled button while GitHub works it out.
    private var tint: Color? {
        switch readiness {
        case .ready: .green
        case .blocked: .red
        case .checking: nil
        }
    }

    private func help(_ pullRequest: PullRequestSummary) -> String {
        switch readiness {
        case .ready: "Merge \(pullRequest.headRefName) into \(pullRequest.baseRefName) with a merge commit"
        case let .blocked(blocker): "Can't merge: \(blocker.description)"
        case .checking: "GitHub is still working out whether this can be merged"
        }
    }
}
