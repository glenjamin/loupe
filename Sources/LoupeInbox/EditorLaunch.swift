import Foundation
import LoupeGit
import Observation

/// Checking an open PR's branch out in its checkout and opening that in an editor: whether it's
/// under way, and what to tell the viewer when it didn't simply work.
@Observable
@MainActor
public final class EditorLaunch {
    public private(set) var isSwitching = false
    /// Shown until dismissed: why the switch or the editor failed, or what was done differently
    /// from what was asked, such as a fork's PR checked out as a local-only branch.
    public var report: EditorLaunchReport?

    init() {}

    fileprivate func run(_ work: () async throws -> EditorLaunchReport?) async {
        guard !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        report = nil
        do {
            report = try await work()
        } catch {
            report = EditorLaunchReport(title: "Couldn't check out the branch", message: error.localizedDescription, isFailure: true)
        }
    }
}

public struct EditorLaunchReport: Sendable, Equatable {
    public let title: String
    public let message: String
    public let isFailure: Bool
}

extension PullRequestTab {
    /// The checkout the diff was made from, which is the one the editor opens; nil until a diff
    /// has resolved one.
    public var editorCheckout: URL? { checkout }

    /// The editor for this PR's checkout, once there is one.
    public var editor: Editor? { checkout.map(Editor.init(for:)) }

    /// Checks the PR's branch out in its checkout, then has `open` open the checkout in its
    /// editor. Refuses a checkout with uncommitted changes, saying so, without touching it.
    public func openInEditor(switcher: CheckoutSwitcher = CheckoutSwitcher(), open: @MainActor (Editor, URL) async throws -> Void) async {
        guard let checkout else { return }
        let pullRequest = pullRequest
        await editorLaunch.run {
            let branch = try await switcher.switchTo(pullRequest: pullRequest.number, of: pullRequest.repository, headRefName: pullRequest.headRefName, in: checkout)
            let editor = Editor(for: checkout)
            do {
                try await open(editor, checkout)
            } catch {
                return EditorLaunchReport(title: "Couldn't open \(editor.name)", message: "\(branch.name) is checked out in \(checkout.path(percentEncoded: false)), but \(error.localizedDescription)", isFailure: true)
            }
            return report(on: branch, in: checkout)
        }
    }
}

/// What to say about a branch that's checked out but not quite as asked; nil when it's
/// simply the PR's branch at its head.
private func report(on branch: SwitchedBranch, in checkout: URL) -> EditorLaunchReport? {
    var notes: [String] = []
    if branch.isFork {
        notes.append("This PR's branch isn't on \(branch.remote), as it's from a fork, so it's checked out as the local branch \(branch.name), which tracks nothing.")
    }
    if !branch.isAtPullRequestHead {
        notes.append("The local branch \(branch.name) has commits the PR doesn't, so it couldn't be fast-forwarded and was left as it was.")
    }
    guard !notes.isEmpty else { return nil }
    return EditorLaunchReport(title: "Checked out \(branch.name) in \(checkout.lastPathComponent)", message: notes.joined(separator: " "), isFailure: false)
}
