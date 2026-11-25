import AppKit
import LoupeCore
import LoupeModel
import SwiftUI

/// The diff palette's status colours, for SwiftUI views.
extension ShapeStyle where Self == Color {
    static var diffSuccess: Color { Color(nsColor: DiffColors.successText) }
    static var diffDanger: Color { Color(nsColor: DiffColors.dangerText) }
    static var diffAttention: Color { Color(nsColor: DiffColors.attentionText) }
}

/// A PR's state in one word, so a tab shows whether its PR is merged or closed, conflicts,
/// awaits changes or is approved without opening it; the lists' badges share its colours. A
/// conflict outranks the rest of an open PR's state, as it's what stands in the way whether the
/// PR is a draft or approved.
enum PullRequestStatus: Equatable {
    case open, draft, conflicts, changesRequested, approved, merged, closed

    init(_ pullRequest: PullRequestSummary) {
        switch pullRequest.state {
        case .merged: self = .merged
        case .closed: self = .closed
        case .open, .unknown:
            if pullRequest.mergeable == .conflicting {
                self = .conflicts
            } else if pullRequest.isDraft {
                self = .draft
            } else {
                switch pullRequest.reviewDecision {
                case .changesRequested: self = .changesRequested
                case .approved: self = .approved
                case .reviewRequired, .unknown, nil: self = .open
                }
            }
        }
    }

    var word: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .conflicts: "Conflicts"
        case .changesRequested: "Changes requested"
        case .approved: "Approved"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    /// Distinct for each status, as a narrow tab shows only a dot of it.
    var colour: NSColor {
        switch self {
        case .open: DiffColors.accentText
        case .draft: DiffColors.subtleText
        case .conflicts: DiffColors.dangerText
        case .changesRequested: DiffColors.severeText
        case .approved: DiffColors.successText
        case .merged: .systemPurple
        case .closed: DiffColors.mutedText
        }
    }

    var tint: Color { Color(nsColor: colour) }
}
