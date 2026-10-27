import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
import SwiftUI

/// The View menu's settings and sections, and the Pull Request and Review menus, acting on the
/// PR shown, or on the lists while they're shown. Diff settings are stored in UserDefaults so
/// open diffs follow them live.
struct DiffCommands: Commands {
    let windows: WindowManager
    @AppStorage(DiffSettings.wrapLinesKey) private var wrapLines = DiffSettings.wrapLinesDefault
    @AppStorage(ListMode.key) private var listMode = ListMode.lists
    @AppStorage("showsClosedPullRequests") private var showsClosed = false
    private let reviewWindows = ReviewWindows.shared

    var body: some Commands {
        let tab = reviewWindows.shownTab
        // Only while the files are shown, where there's a file to act on.
        let filesTab = tab.flatMap { $0.section == .files ? $0 : nil }
        CommandGroup(after: .toolbar) {
            Button(tab == nil ? "Refresh" : "Reload") {
                if let tab { Task { await tab.reload() } } else { Task { await windows.tabs.lists.refresh() } }
            }
            .keyboardShortcut(.refresh)
            .disabled(tab == nil && windows.tabs.lists.isLoading)
            Divider()
            Toggle("Wrap Lines", isOn: $wrapLines)
                .keyboardShortcut(.wrapLines)
            // The shown PR's alone: whether it helps depends on the PR.
            Toggle("Hide Whitespace", isOn: Binding(get: { tab?.hidesWhitespace ?? false }, set: { hides in
                if let tab { Task { await tab.setHidesWhitespace(hides) } }
            }))
                .keyboardShortcut(.hideWhitespace)
                .disabled(tab == nil)
            Button("Show Rendered or Diff") { filesTab?.toggleRendered() }
                .keyboardShortcut(.toggleRendered)
                .disabled(filesTab?.canToggleRendered != true)
            Button("Hide Revealed Lines") { filesTab?.hideRevealedLines() }
                .keyboardShortcut(.hideRevealedLines)
                .disabled(filesTab?.selectedFileDiff.map { filesTab?.hasRevealedContext(of: $0) == true } != true)
            Divider()
            Button("Conversation") { tab?.section = .conversation }
                .keyboardShortcut(.conversation)
                .disabled(tab == nil)
            Button("Files Changed") { tab?.section = .files }
                .keyboardShortcut(.files)
                .disabled(tab == nil)
            Button("Visual Review") { tab?.showVisualReview() }
                .keyboardShortcut(.visualReview)
                .disabled(tab?.visualReview == nil)
            Divider()
            Button(listMode == .todo ? "Show Lists" : "Show TODO") { listMode = listMode == .todo ? .lists : .todo }
                .keyboardShortcut(.toggleTodo)
            // The TODO view is of open PRs only.
            Toggle("Show Closed and Merged", isOn: $showsClosed)
                .keyboardShortcut(.showClosed)
                .disabled(listMode == .todo)
            Divider()
        }
        CommandMenu("Pull Request") {
            Button("Open on GitHub") { if let tab { openInBrowser(tab.pullRequest.url) } }
                .keyboardShortcut(.openOnGitHub)
                .disabled(tab == nil)
            Button("Copy Link") { if let tab { copyLink(tab.pullRequest.url) } }
                .keyboardShortcut(.copyLink)
                .disabled(tab == nil)
            Button("Open in \(tab?.editor?.name ?? "Editor")") {
                if let tab { Task { await tab.openInEditor { editor, directory in try await open(directory, in: editor) } } }
            }
            .keyboardShortcut(.openInEditor)
            .disabled(tab?.editor == nil || tab?.editorLaunch.isSwitching == true)
            Divider()
            Button("Edit Description") {
                guard let tab else { return }
                tab.section = .conversation
                Task { await tab.editDescription() }
            }
            .keyboardShortcut(.editDescription)
            .disabled(tab?.canEditDescription != true || tab?.descriptionEditor != nil)
            Button("Reviewers…") { tab?.isAskingReviewers = true }
                .keyboardShortcut(.reviewers)
                .disabled(tab?.reviewers == nil)
            Button("Merge…") { tab?.isConfirmingMerge = true }
                .keyboardShortcut(.merge)
                .disabled(tab?.mergeReadiness != .ready || tab?.isMerging == true)
        }
        CommandMenu("Review") {
            Button("Summary…") {
                guard let tab else { return }
                tab.startWritingSummary()
                tab.reviewDraft.isWritingSummary = true
            }
            .keyboardShortcut(.summary)
            .disabled(tab?.showsReviewControls != true)
            verdictItem(.approve, shortcut: .approve, tab: tab)
            verdictItem(.requestChanges, shortcut: .requestChanges, tab: tab)
            verdictItem(.comment, shortcut: .submitReview, tab: tab)
            Divider()
            Button("Mark Reviewed and Show Next File") {
                if let filesTab { Task { await filesTab.markViewedAndAdvance() } }
            }
            .keyboardShortcut(.markReviewedAndNext)
            .disabled(filesTab?.selectedFile == nil)
            // The plain keys work only through `ReviewWindows`' key monitor: as menu shortcuts
            // they would take those keys from every text field.
            Button(plainKeyTitle("Toggle Reviewed", .toggleReviewed)) {
                if let filesTab, let path = filesTab.selectedFile { Task { await filesTab.toggleViewed(path: path) } }
            }
            .disabled(filesTab?.selectedFile == nil)
            Button(plainKeyTitle("Next File", .nextFile)) { filesTab?.selectAdjacentFile(1) }
                .disabled(filesTab == nil)
            Button(plainKeyTitle("Previous File", .previousFile)) { filesTab?.selectAdjacentFile(-1) }
                .disabled(filesTab == nil)
            Button(plainKeyTitle("Next Commit", .nextCommit)) {
                if let filesTab { Task { await filesTab.showAdjacentCommit(1) } }
            }
            .disabled(filesTab == nil)
            Button(plainKeyTitle("Previous Commit", .previousCommit)) {
                if let filesTab { Task { await filesTab.showAdjacentCommit(-1) } }
            }
            .disabled(filesTab == nil)
        }
        CommandGroup(replacing: .help) {
            Button(plainKeyTitle("Keyboard Shortcuts", .showShortcuts)) { reviewWindows.showShortcuts() }
        }
    }

    /// Asks to confirm submitting the review as `event`, as a click on its button doesn't.
    private func verdictItem(_ event: ReviewEvent, shortcut: Shortcut, tab: PullRequestTab?) -> some View {
        Button("\(event.title)…") { if let tab { reviewWindows.confirm(event, of: tab) } }
            .keyboardShortcut(shortcut)
            .disabled(tab.map { !$0.showsReviewControls || !$0.canSubmitReview(as: event) } ?? true)
    }

    private func plainKeyTitle(_ title: String, _ shortcut: Shortcut) -> String {
        "\(title) (\(shortcut.keys.first ?? ""))"
    }
}

enum DiffSettings {
    static let wrapLinesKey = "wrapLines"
    static let wrapLinesDefault = true
}

/// Which PR the window shows, and so which PR the review keys act on: the plain keys of
/// `Shortcut`, taken unless the focus is somewhere text can be typed. `?` lists every shortcut
/// anywhere in the window; the rest act on the files shown, but `r`, which quotes text selected
/// in a comment into a reply, in either section.
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

    /// Asks to confirm submitting `tab`'s review as `verdict`, in a sheet over the window.
    func confirm(_ verdict: ReviewEvent, of tab: PullRequestTab) {
        if let window = window ?? NSApp.keyWindow { VerdictConfirmation.ask(verdict, of: tab, in: window) }
    }

    /// Lists every shortcut in a sheet over the window.
    func showShortcuts() {
        if let window = window ?? NSApp.keyWindow { ShortcutsPanel.show(in: window) }
    }

    /// Whether `event` was a review key, now acted on.
    private func handle(_ event: NSEvent) -> Bool {
        if let window = event.window, window.isKeyWindow, quote(event, in: window) { return true }
        guard let window = event.window, window === self.window, window.isKeyWindow, !TextEditingKeys.isTyping(in: window) else { return false }
        if Shortcut.showShortcuts.matches(event) {
            ShortcutsPanel.show(in: window)
            return true
        }
        guard let tab = shownTab, tab.section == .files else { return false }
        if Shortcut.nextFile.matches(event) || Shortcut.previousFile.matches(event) {
            tab.selectAdjacentFile(Shortcut.nextFile.matches(event) ? 1 : -1)
            return true
        }
        if Shortcut.nextCommit.matches(event) || Shortcut.previousCommit.matches(event) {
            let step = Shortcut.nextCommit.matches(event) ? 1 : -1
            Task { await tab.showAdjacentCommit(step) }
            return true
        }
        guard let path = tab.selectedFile else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if Shortcut.markReviewedAndNext.matches(event) || (event.specialKey == .downArrow && modifiers == .command) {
            Task { await tab.markViewedAndAdvance() }
            return true
        }
        if Shortcut.toggleReviewed.matches(event) {
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
        guard Shortcut.quoteReply.matches(event), let tab = shownTab, !TextEditingKeys.isTyping(in: window) else { return false }
        if quoteSelectedComment(in: window, of: tab) { return true }
        guard tab.section == .conversation, let page = ConversationPage.existingPage(for: tab),
              let responder = window.firstResponder as? NSView, responder.isDescendant(of: page.webView) else { return false }
        Task { await page.quoteSelection() }
        return true
    }
}

extension PullRequestTab {
    /// Whether the header shows the viewer's review controls: on anyone else's open PR, and on
    /// any other once a review is pending.
    var showsReviewControls: Bool {
        canReview || (canStartReview && pendingReview != nil)
    }

    /// Whether the shown file can be switched between its diff and a rendering of it.
    var canToggleRendered: Bool {
        guard let file = selectedFileDiff else { return false }
        return markdownPreview(of: file) != nil || imagePreview(of: file)?.isSVG == true || packageLockPreview(of: file).map { $0.failure == nil } == true
    }

    /// Switches the shown file between its diff and its rendering, as its header's picker does.
    func toggleRendered() {
        guard let file = selectedFileDiff else { return }
        if let markdown = markdownPreview(of: file) {
            markdown.setRendered(!markdown.isRendered)
        } else if let image = imagePreview(of: file), image.isSVG {
            image.setRendered(!image.isRendered)
        } else if let packageLock = packageLockPreview(of: file), packageLock.failure == nil {
            packageLock.setShowsRawDiff(!packageLock.showsRawDiff)
        }
    }

    func hideRevealedLines() {
        if let file = selectedFileDiff { collapseContext(of: file) }
    }
}
