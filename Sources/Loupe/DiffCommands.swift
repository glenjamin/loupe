import AppKit
import LoupeInbox
import SwiftUI

/// Diff-view settings in the View menu, stored in UserDefaults so open diffs follow them live,
/// and the review commands for the frontmost PR's shown file.
struct DiffCommands: Commands {
    @AppStorage(DiffSettings.wrapLinesKey) private var wrapLines = DiffSettings.wrapLinesDefault
    @AppStorage(DiffSettings.splitDiffKey) private var splitDiff = DiffSettings.splitDiffDefault
    private let windows = ReviewWindows.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Wrap Lines", isOn: $wrapLines)
                .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("Split Diff", isOn: $splitDiff)
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            // ⌃ rather than ⌘, which picks the PR tab by number.
            Button("Conversation") { windows.shownTab?.section = .conversation }
                .keyboardShortcut("1", modifiers: .control)
                .disabled(windows.shownTab == nil)
            Button("Files Changed") { windows.shownTab?.section = .files }
                .keyboardShortcut("2", modifiers: .control)
                .disabled(windows.shownTab == nil)
        }
        CommandMenu("Review") {
            // Only while the files are shown, where there's a file to act on.
            let tab = windows.shownTab.flatMap { $0.section == .files ? $0 : nil }
            Button("Mark Reviewed and Show Next File") {
                if let tab { Task { await tab.markViewedAndAdvance() } }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(tab?.selectedFile == nil)
            // ⇧V and ] work too, but only through `ReviewWindows`' key monitor: as menu
            // shortcuts they would take those keys from every text field.
            Button("Toggle Reviewed (⇧V)") {
                if let tab, let path = tab.selectedFile { Task { await tab.toggleViewed(path: path) } }
            }
            .disabled(tab?.selectedFile == nil)
        }
    }
}

enum DiffSettings {
    static let wrapLinesKey = "wrapLines"
    static let wrapLinesDefault = true
    /// Old beside new, rather than one column; narrow views show unified whatever it says.
    static let splitDiffKey = "splitDiff"
    static let splitDiffDefault = false
}

/// Which PR the window shows, and so which PR the review keys act on. ⌘↓ and `]` mark the shown
/// file viewed and show the next one, and ⇧V toggles it, unless the focus is somewhere text can
/// be typed. `r` quotes text selected in a comment into a reply, in either section.
@Observable
@MainActor
final class ReviewWindows {
    static let shared = ReviewWindows()

    /// The shown PR, nil while the lists are shown.
    private(set) var shownTab: PullRequestTab?
    @ObservationIgnored private weak var window: NSWindow?

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread, where the event came from.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
    }

    /// Records that `window` now shows `tab`, or the lists for nil.
    func show(_ tab: PullRequestTab?, in window: NSWindow?) {
        if shownTab !== tab { shownTab = tab }
        self.window = window
    }

    /// Whether `event` was a review key, now acted on.
    private func handle(_ event: NSEvent) -> Bool {
        if let window = event.window, window.isKeyWindow, quote(event, in: window) { return true }
        guard let window = event.window, window === self.window, window.isKeyWindow, let tab = shownTab,
              tab.section == .files, let path = tab.selectedFile, !isTyping(in: window)
        else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers ?? ""
        if (key == "]" && modifiers.isEmpty) || (event.specialKey == .downArrow && modifiers == .command) {
            Task { await tab.markViewedAndAdvance() }
            return true
        }
        if key.lowercased() == "v" && modifiers == .shift {
            Task { await tab.toggleViewed(path: path) }
            return true
        }
        return false
    }

    /// Whether `event` was `r` with text selected in a comment of the shown PR, in `window` or
    /// a popover over it, now quoted into a reply as github.com does. The conversation page's
    /// selection is read asynchronously, so `r` there is taken whatever is selected; the page
    /// has nothing to type into.
    func quote(_ event: NSEvent, in window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.charactersIgnoringModifiers == "r", modifiers.isEmpty, let tab = shownTab, !isTyping(in: window) else { return false }
        if quoteSelectedComment(in: window, of: tab) { return true }
        guard tab.section == .conversation, let page = ConversationPage.existingPage(for: tab),
              let responder = window.firstResponder as? NSView, responder.isDescendant(of: page.webView) else { return false }
        Task { await page.quoteSelection() }
        return true
    }
}

/// Whether the focus is in a field or editor that takes typing, such as the find bar.
@MainActor
private func isTyping(in window: NSWindow) -> Bool {
    guard let text = window.firstResponder as? NSTextView else { return false }
    return text.isEditable
}
