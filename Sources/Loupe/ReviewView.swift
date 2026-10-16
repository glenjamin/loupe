import AppKit
import LoupeCore
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
                    Button { draft.isListingPending = true } label: {
                        Text(verbatim: "\(count) pending \(count == 1 ? "comment" : "comments")")
                            .font(.caption)
                            .foregroundStyle(.diffAttention)
                    }
                    .buttonStyle(.plain)
                    .help("List the comments in your pending review")
                    .background(PendingCommentsButtonMarker())
                    .popover(isPresented: $draft.isListingPending, arrowEdge: .bottom) {
                        PendingCommentsPopover(tab: tab, draft: draft)
                    }
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
                .help(tab.pendingReview == nil
                    ? "Write the review's summary, sent with whichever of the buttons above you click"
                    : "Write the review's summary, sent with whichever of the buttons above you click, or discard the pending review")
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
/// With a review pending, it's also where the review is discarded.
private struct SummaryPopover: View {
    let tab: PullRequestTab
    @Bindable var draft: ReviewDraft

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
                    DiscardReviewButton(tab: tab)
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
    }

    private func close() {
        draft.isWritingSummary = false
    }
}

/// The comments in the viewer's pending review, in the diff's order, each saying where it is
/// and what it answers. Choosing one shows it in the diff; each can be deleted, or the whole
/// review discarded, from here.
private struct PendingCommentsPopover: View {
    let tab: PullRequestTab
    @Bindable var draft: ReviewDraft

    var body: some View {
        let comments = tab.pendingComments
        VStack(alignment: .leading, spacing: 10) {
            Text("Your pending review")
                .font(.headline)
            if comments.isEmpty {
                Text("It has no comments.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, pending in
                            if index > 0 { Divider() }
                            PendingCommentRow(tab: tab, pending: pending) { draft.isListingPending = false }
                        }
                    }
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }
            HStack(spacing: 8) {
                DiscardReviewButton(tab: tab)
                Spacer(minLength: 0)
                Button("Done") { draft.isListingPending = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 440)
    }
}

/// A pending comment in the list: its place, what it answers, then the start of what it says.
private struct PendingCommentRow: View {
    let tab: PullRequestTab
    let pending: PendingComment
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                close()
                Task { await tab.follow(ThreadLink(.show, thread: pending.thread.id)) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: place(of: pending.thread))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let context {
                        Text(verbatim: context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(verbatim: excerpt)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            DeletePendingCommentButton(tab: tab, thread: pending.thread, comment: pending.comment)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// "replying to @alice: …" for a reply, else the line of code it's on.
    private var context: String? {
        if let parent = pending.replyingTo {
            let line = plainLines(of: commentBlocks(parent.bodyHTML)).first ?? ""
            return "replying to @\(parent.author?.login ?? "ghost"): \(line)"
        }
        return pending.commentedCode
    }

    /// The comment's first few lines, with an ellipsis when there's more.
    private var excerpt: String {
        let lines = plainLines(of: commentBlocks(pending.comment.bodyHTML))
        let shown = lines.prefix(3).joined(separator: "\n")
        return lines.count > 3 ? shown + "…" : shown
    }
}

/// Discards the viewer's pending review, naming how many comments go with it, after asking.
private struct DiscardReviewButton: View {
    let tab: PullRequestTab
    @State private var confirmsDiscard = false

    var body: some View {
        let count = tab.pendingReview?.commentCount ?? 0
        Button(role: .destructive) { confirmsDiscard = true } label: {
            Text(verbatim: count == 0 ? "Discard review…" : "Discard review with \(count) pending \(count == 1 ? "comment" : "comments")…")
        }
        .disabled(tab.reviewDraft.isSubmitting)
        .help("Delete your pending review and its comments")
        .alert("Discard your review?", isPresented: $confirmsDiscard) {
            Button("Discard Review", role: .destructive) { Task { await tab.discardReview() } }
            Button("Keep Reviewing", role: .cancel) {}
        } message: {
            Text(verbatim: count == 0
                ? "It has no comments. No one else has seen it."
                : "Its \(count) pending \(count == 1 ? "comment is" : "comments are") deleted. No one else has seen \(count == 1 ? "it" : "them").")
        }
    }
}

/// An empty view behind "Summary…", so a snapshot run can find where it is.
struct SummaryButtonMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

/// An empty view behind the pending count, so a snapshot run can find where it is.
struct PendingCommentsButtonMarker: NSViewRepresentable {
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

/// A comment's text as plain lines, blank ones dropped, for an excerpt read at a glance.
private func plainLines(of blocks: [CommentBlock]) -> [String] {
    blocks.flatMap { block -> [String] in
        switch block {
        case let .text(text, _): String(text.characters).components(separatedBy: .newlines)
        case let .code(code): code.components(separatedBy: .newlines)
        case let .quote(inner): plainLines(of: inner).map { "> \($0)" }
        case .rule: []
        }
    }
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
}
