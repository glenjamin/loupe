import AppKit
import LoupeInbox
import LoupeModel
import SwiftUI

/// On anyone else's open PR, the header's review controls where the reviewers sit on the
/// viewer's own: Request changes, Submit and Approve, each submitting at once with the summary
/// written so far, and under them the pending count and "Summary…" to write it.
struct ReviewControls: View {
    let tab: PullRequestTab

    var body: some View {
        @Bindable var draft = tab.reviewDraft
        // The row sets the width; the pending count and any refusal wrap within it.
        RowWidthStack(spacing: 4) {
            HStack(spacing: 6) {
                verdictButton(.requestChanges)
                verdictButton(.comment)
                verdictButton(.approve)
            }
            HStack(spacing: 6) {
                if let count = tab.pendingReview?.commentCount {
                    Text(verbatim: "\(count) pending \(count == 1 ? "comment" : "comments")")
                        .font(.caption)
                        .foregroundStyle(.diffAttention)
                }
                Spacer(minLength: 0)
                if draft.isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Button("Summary…", systemImage: tab.reviewSummary.isEmpty ? "text.bubble" : "text.bubble.fill") {
                    tab.startWritingSummary()
                    draft.isWritingSummary = true
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Write the review's summary, sent with whichever of the buttons above you click")
                .background(SummaryButtonMarker())
                .popover(isPresented: $draft.isWritingSummary, arrowEdge: .bottom) {
                    SummaryPopover(tab: tab, draft: draft)
                }
            }
            if let error = draft.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.diffDanger)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(error)
            }
        }
        .fixedSize()
    }

    private func verdictButton(_ event: ReviewEvent) -> some View {
        Button {
            Task { await tab.submitReview(as: event) }
        } label: {
            Label {
                Text(event.title)
            } icon: {
                Image(systemName: event.symbol)
                    .foregroundStyle(event.colour ?? .primary)
            }
        }
        .buttonStyle(.bordered)
        .tint(event.colour)
        .disabled(!tab.canSubmitReview(as: event))
        .help(help(for: event))
    }

    private func help(for event: ReviewEvent) -> String {
        if !tab.canSubmitReview(as: event), !tab.reviewDraft.isSubmitting {
            return "Write a summary or add comments first, to \(event == .requestChanges ? "request changes" : "submit without approving")"
        }
        let pending = tab.pendingReview.map { " with its \($0.commentCount) pending \($0.commentCount == 1 ? "comment" : "comments")" } ?? ""
        return "\(event.summary) Submits your review\(pending) now."
    }
}

/// The review's summary on its own, kept as it's written; whichever verdict is clicked sends it.
/// With a review pending, it's also where the review is abandoned.
private struct SummaryPopover: View {
    let tab: PullRequestTab
    @Bindable var draft: ReviewDraft
    @State private var confirmsAbandon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review summary")
                .font(.headline)
            // ⌘↩ and Escape only close it: the verdict is chosen in the header.
            MarkdownTextView(text: $draft.body, isEditable: !draft.isSubmitting, save: close, cancel: close, font: .systemFont(ofSize: NSFont.systemFontSize))
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            Text("Leave a comment. Markdown. Sent with Request changes, Submit or Approve.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = draft.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.diffDanger)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(error)
            }
            HStack(spacing: 8) {
                if tab.pendingReview != nil {
                    Button("Abandon review", role: .destructive) { confirmsAbandon = true }
                        .disabled(draft.isSubmitting)
                        .help("Delete your pending review and its comments")
                }
                Spacer(minLength: 0)
                if draft.isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .help("Keep the summary for when you submit (⌘↩)")
            }
        }
        .padding(12)
        .frame(width: 400)
        .alert("Abandon your review?", isPresented: $confirmsAbandon) {
            Button("Abandon Review", role: .destructive) { Task { await tab.abandonReview() } }
            Button("Keep Reviewing", role: .cancel) {}
        } message: {
            Text(abandonMessage)
        }
    }

    private func close() {
        draft.isWritingSummary = false
    }

    private var abandonMessage: String {
        let count = tab.pendingReview?.commentCount ?? 0
        return "Its \(count) pending \(count == 1 ? "comment is" : "comments are") deleted. No one else has seen \(count == 1 ? "it" : "them")."
    }
}

/// An empty view behind "Summary…", so a snapshot run can find where it is.
struct SummaryButtonMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

/// A column as wide as its first subview's own size, each later one proposed that width, so
/// text under a row of buttons wraps rather than widening the header's reviews section.
private struct RowWidthStack: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(subviews: Subviews) -> [CGRect] {
        guard let first = subviews.first else { return [] }
        let width = first.sizeThatFits(.unspecified).width
        var y: CGFloat = 0
        return subviews.map { subview in
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            defer { y += size.height + spacing }
            return CGRect(x: 0, y: y, width: width, height: size.height)
        }
    }
}

private extension ReviewEvent {
    var title: String {
        switch self {
        case .comment: "Submit"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        }
    }

    var symbol: String {
        switch self {
        case .comment: "paperplane"
        case .approve: "checkmark.circle"
        case .requestChanges: "xmark.circle"
        }
    }

    var colour: Color? {
        switch self {
        case .comment: nil
        case .approve: .diffSuccess
        case .requestChanges: .diffDanger
        }
    }

    /// github.com's own words.
    var summary: String {
        switch self {
        case .comment: "Submit general feedback without explicit approval."
        case .approve: "Give your approval to merge these changes."
        case .requestChanges: "Submit feedback that must be addressed before merging."
        }
    }
}
