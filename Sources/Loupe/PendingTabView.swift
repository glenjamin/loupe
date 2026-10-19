import LoupeInbox
import SwiftUI

/// The pane of a link's tab while its PR is looked up, waiting as a PR's own panes do, or once
/// that's failed, why, with the choice to try again or close the tab.
struct PendingTabView: View {
    let pending: PendingTab
    let retry: @MainActor () -> Void
    let close: @MainActor () -> Void

    var body: some View {
        let identity = "\(pending.link.repository) #\(pending.link.number)"
        if let error = pending.error {
            ContentUnavailableView {
                Label("Couldn't open the pull request", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                HStack {
                    Button("Retry", action: retry)
                    Button("Open on GitHub") { openInBrowser(pending.url) }
                    Button("Close", action: close)
                }
                // Each button as wide as its title, which the view would otherwise squeeze.
                .fixedSize()
            }
        } else {
            LoadingLabel(title: "Looking up the pull request…", detail: identity)
        }
    }
}
