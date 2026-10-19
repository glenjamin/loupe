import LoupeInbox
import LoupeModel
import SwiftUI

/// The PR's stack across the header, bottom first as GitHub's stack map reads up from the
/// base: `gazette #277 → #278 → #281`, each with its review glyph. This PR is in bold; clicking
/// any other opens it, or shows its tab. Where several PRs are stacked on one they're side by
/// side, and the line ends there.
struct StackBar: View {
    let line: StackLine
    let tab: PullRequestTab

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up")
                .help("Stacked pull requests, from the bottom up")
            ForEach(Array(line.levels.enumerated()), id: \.offset) { index, level in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(level.enumerated()), id: \.element.id) { sibling, pullRequest in
                    if sibling > 0 {
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                    }
                    entry(pullRequest, named: index == 0)
                }
            }
        }
    }

    @ViewBuilder
    private func entry(_ pullRequest: PullRequestSummary, named: Bool) -> some View {
        let label = HStack(spacing: 3) {
            Text(verbatim: named ? "\(repositoryName(pullRequest)) #\(pullRequest.number)" : "#\(pullRequest.number)")
                .monospacedDigit()
            StackReviewGlyph(pullRequest: pullRequest)
        }
        if pullRequest.id == line.current {
            label
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .help("This PR: \(pullRequest.title)")
        } else {
            Button {
                Task { await tab.open(PullRequestLink(repository: pullRequest.repository, number: pullRequest.number)) }
            } label: {
                label.contentShape(Rectangle())
            }
            .background(StackEntryMarker())
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Open \(repositoryName(pullRequest)) #\(pullRequest.number): \(pullRequest.title) (\(StackReviewGlyph.words(pullRequest)))")
        }
    }
}

/// Where a stacked PR's review stands, as a small glyph: a draft, approved, changes requested,
/// or waiting on review.
struct StackReviewGlyph: View {
    let pullRequest: PullRequestSummary

    var body: some View {
        Group {
            if pullRequest.isDraft {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            } else {
                switch pullRequest.reviewDecision {
                case .approved: Image(systemName: "checkmark.circle.fill").foregroundStyle(.diffSuccess)
                case .changesRequested: Image(systemName: "xmark.circle.fill").foregroundStyle(.diffDanger)
                case .reviewRequired, .unknown, nil: Image(systemName: "circle").foregroundStyle(.diffAttention)
                }
            }
        }
        .imageScale(.small)
    }

    static func words(_ pullRequest: PullRequestSummary) -> String {
        if pullRequest.isDraft { return "draft" }
        return switch pullRequest.reviewDecision {
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .reviewRequired, .unknown, nil: "awaiting review"
        }
    }
}

/// Beneath the Merge button of a PR stacked on another that's still open: which to merge first.
/// Only a reminder; the button is as GitHub's merge state has it.
struct MergeFirstLabel: View {
    let parent: PullRequestSummary

    var body: some View {
        Label {
            Text(verbatim: "Merge #\(parent.number) first")
        } icon: {
            Image(systemName: "square.stack.3d.up")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("This is stacked on \(repositoryName(parent)) #\(parent.number), \(parent.title), which isn't merged yet")
    }
}

/// Lets the snapshot run find the stack bar's other PRs to click.
struct StackEntryMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}
