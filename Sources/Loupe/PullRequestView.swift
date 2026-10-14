import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
import SwiftUI

/// One PR's tab: its header, then its diff once produced from the local checkout.
struct PullRequestView: View {
    @Bindable var tab: PullRequestTab
    let checkoutSearchRoots: [URL]

    var body: some View {
        let pullRequest = tab.pullRequest
        VStack(spacing: 0) {
            PullRequestHeader(pullRequest: pullRequest)
            Divider()
            content(pullRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Showing the tab, or a refresh moving the PR's head, produces the diff if it isn't
        // already in memory for that head.
        .task(id: pullRequest.headRefOid) { await tab.load() }
    }

    @ViewBuilder
    private func content(_ pullRequest: PullRequestSummary) -> some View {
        switch tab.phase {
        case .resolvingCheckout:
            ProgressView("Finding the local checkout…")
        case .noCheckout:
            ContentUnavailableView {
                Label("No local checkout of \(pullRequest.repository)", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Diffs come from a local checkout. None was found named \(repositoryName(pullRequest)) under \(checkoutSearchRoots.map { $0.path(percentEncoded: false) }.formatted()).")
            } actions: {
                Button("Locate Checkout…") {
                    locateCheckout(of: pullRequest.repository, startingAt: checkoutSearchRoots.first) { directory in
                        try await tab.locateCheckout(at: directory)
                    }
                }
            }
        case .fetching:
            ProgressView("Fetching #\(pullRequest.number) from origin…")
        case .diffing:
            ProgressView("Diffing…")
        case let .ready(diff):
            FileBrowser(files: diff.files, hiddenCount: diff.hiddenCount, selection: $tab.selectedFile)
                // A new head can change a file under the same path.
                .id(diff.headOid)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't produce the diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await tab.retry() } }
            }
        }
    }
}

struct PullRequestHeader: View {
    let pullRequest: PullRequestSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(repositoryName(pullRequest)) #\(pullRequest.number)")
                        .font(.headline.monospacedDigit())
                    StateBadge(pullRequest: pullRequest, showsOpen: true)
                    Text(pullRequest.title)
                        .font(.title3)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    if let author = pullRequest.author {
                        Label(author, systemImage: "person")
                    }
                    Text("\(pullRequest.headRefName) → \(pullRequest.baseRefName)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    if let checks = pullRequest.checks {
                        ChecksIcon(state: checks)
                    }
                    if let decision = pullRequest.reviewDecision {
                        ReviewDecisionLabel(decision: decision)
                    }
                    TimelineView(.everyMinute) { _ in
                        Text("updated \(pullRequest.updatedAt.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The changed files beside the selected file's diff.
struct FileBrowser: View {
    let files: [FileDiff]
    let hiddenCount: Int
    @Binding var selection: FileDiff.ID?

    var body: some View {
        HSplitView {
            FileList(files: files, hiddenCount: hiddenCount, selection: $selection)
                .frame(minWidth: 200, idealWidth: 300, maxWidth: 500)
            Group {
                if let file = files.first(where: { $0.id == selection }) {
                    DiffView(file: file) { anchor in print("clicked \(anchor)") }
                } else {
                    Text(files.isEmpty ? "No changes to review" : "No file selected")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400)
        }
    }
}

/// Asks for the repo's checkout directory and hands it to `locate`, saying so if it's rejected.
@MainActor
func locateCheckout(of repository: String, startingAt directory: URL?, locate: @escaping @MainActor (URL) async throws -> Void) {
    let panel = NSOpenPanel()
    panel.message = "Choose the local checkout of \(repository)"
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = directory
    guard panel.runModal() == .OK, let chosen = panel.url else { return }
    Task {
        do {
            try await locate(chosen)
        } catch {
            let alert = NSAlert()
            alert.messageText = "That isn't a checkout of \(repository)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// The repo's name without its owner.
func repositoryName(_ pullRequest: PullRequestSummary) -> String {
    pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository
}
