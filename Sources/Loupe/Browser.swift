import AppKit
import LoupeModel

/// Opens a link in the default browser. Every link Loupe sends there goes through here, so
/// GitHub's are marked as Loupe's own and a link router doesn't hand them straight back.
@MainActor
func openInBrowser(_ url: URL) {
    guard !SnapshotRun.refuses("open \(url.absoluteString) in the browser") else { return }
    NSWorkspace.shared.open(browserURL(for: url))
}
