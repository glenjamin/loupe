import AppKit
import LoupeInbox
import LoupeModel
import SwiftUI

/// On anyone else's open PR, the header's review control where the reviewers sit on the
/// viewer's own: "Review", or "Finish review (N)" with N comments pending, opening github.com's
/// "Finish your review" as a popover.
struct ReviewButton: View {
    let tab: PullRequestTab

    var body: some View {
        @Bindable var draft = tab.reviewDraft
        Button(title, systemImage: "text.bubble") {
            tab.startFinishingReview()
            draft.isFinishing = true
        }
        .buttonStyle(.borderedProminent)
        .help(help)
        .background(ReviewButtonMarker())
        .popover(isPresented: $draft.isFinishing, arrowEdge: .bottom) {
            FinishReviewPopover(tab: tab, draft: draft)
        }
        .fixedSize()
    }

    private var title: String {
        guard let count = tab.pendingReview?.commentCount else { return "Review" }
        return "Finish review (\(count))"
    }

    private var help: String {
        guard let count = tab.pendingReview?.commentCount else { return "Comment on, approve or request changes to this pull request" }
        return "Submit your review with its \(count) pending \(count == 1 ? "comment" : "comments"), or abandon it"
    }
}

/// A summary, a verdict and Submit, as github.com's "Finish your review" has them, and with a
/// review pending a way to abandon it. ⌘↩ submits; GitHub's refusal shows here.
private struct FinishReviewPopover: View {
    let tab: PullRequestTab
    @Bindable var draft: ReviewDraft
    @State private var confirmsAbandon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Finish your review")
                    .font(.headline)
                Spacer(minLength: 0)
                if let count = tab.pendingReview?.commentCount {
                    Text(verbatim: "\(count) pending \(count == 1 ? "comment" : "comments")")
                        .font(.caption)
                        .foregroundStyle(.diffAttention)
                }
            }
            MarkdownTextView(text: $draft.body, isEditable: !draft.isSubmitting, save: submit, cancel: { draft.isFinishing = false }, font: .systemFont(ofSize: NSFont.systemFontSize))
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            Text("Leave a comment. Markdown.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ReviewEvent.allCases, id: \.self) { event in
                    EventOption(event: event, selected: $draft.event, refusal: refusal(of: event))
                }
            }
            .disabled(draft.isSubmitting)
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
                Button("Submit review", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!tab.canSubmitReview)
                    .help(submitHelp)
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

    private func submit() {
        guard tab.canSubmitReview else { return }
        Task { await tab.submitReview() }
    }

    /// Why GitHub won't take `event` here, if it won't.
    private func refusal(of event: ReviewEvent) -> String? {
        guard tab.isOwnPullRequest else { return nil }
        switch event {
        case .comment: return nil
        case .approve: return "You can't approve your own pull request"
        case .requestChanges: return "You can't request changes on your own pull request"
        }
    }

    private var submitHelp: String {
        tab.canSubmitReview ? "Submit review (⌘↩)" : "Leave a comment to submit a review that doesn't approve"
    }

    private var abandonMessage: String {
        let count = tab.pendingReview?.commentCount ?? 0
        return "Its \(count) pending \(count == 1 ? "comment is" : "comments are") deleted. No one else has seen \(count == 1 ? "it" : "them")."
    }
}

/// One verdict as a radio button, with GitHub's description of it beneath.
private struct EventOption: View {
    let event: ReviewEvent
    @Binding var selected: ReviewEvent
    let refusal: String?

    var body: some View {
        Button { selected = event } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: selected == event ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected == event ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                    Text(event.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(refusal != nil)
        .help(refusal ?? event.summary)
    }
}

/// An empty view behind the Review button, so a snapshot run can find where it is.
struct ReviewButtonMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

private extension ReviewEvent {
    var title: String {
        switch self {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
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
