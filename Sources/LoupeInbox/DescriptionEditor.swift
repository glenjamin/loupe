import Foundation
import LoupeGitHub
import Observation

/// Editing a PR's description. It starts from the description as it is on GitHub when the
/// editor opens, not the stored copy, so edits made on github.com since aren't overwritten.
@Observable
@MainActor
public final class DescriptionEditor {
    public enum Phase: Sendable, Equatable {
        /// Asking GitHub for the description as it is now.
        case fetching
        /// GitHub couldn't be asked, and why; there's nothing safe to edit until it can.
        case fetchFailed(String)
        case editing
        /// Sending the draft, then fetching the conversation again to show GitHub's rendering.
        case saving
    }

    public private(set) var phase = Phase.fetching
    /// The text being edited.
    public var draft = ""
    /// The description as GitHub had it when editing began.
    public private(set) var original = ""
    /// Why GitHub refused the last save, until another is tried.
    public private(set) var saveError: String?

    private let pullRequestId: String
    private let client: GitHubClient

    init(pullRequestId: String, client: GitHubClient) {
        self.pullRequestId = pullRequestId
        self.client = client
    }

    /// Whether the draft differs from what GitHub had.
    public var hasChanges: Bool {
        switch phase {
        case .editing, .saving: draft != original
        case .fetching, .fetchFailed: false
        }
    }

    public var canSave: Bool {
        phase == .editing && hasChanges
    }

    /// Asks GitHub for the description to edit, such as again after a failure.
    public func fetch() async {
        phase = .fetching
        do {
            // GitHub keeps line endings as typed in a browser; the editor's are newlines, so a
            // description no one has touched isn't counted as changed.
            let body = try await client.pullRequestBody(id: pullRequestId).replacingOccurrences(of: "\r\n", with: "\n")
            original = body
            draft = body
            phase = .editing
        } catch {
            phase = .fetchFailed(error.localizedDescription)
        }
    }

    /// Sends the draft to GitHub. On success it stays saving, for whoever opened it to close;
    /// on failure the draft is kept and the reason shown.
    func save() async -> Bool {
        guard canSave else { return false }
        phase = .saving
        saveError = nil
        do {
            try await client.updatePullRequestBody(draft, pullRequestId: pullRequestId)
            return true
        } catch {
            saveError = "Couldn't save the description: \(error.localizedDescription)"
            phase = .editing
            return false
        }
    }
}
