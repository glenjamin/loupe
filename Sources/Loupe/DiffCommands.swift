import AppKit
import LoupeInbox
import SwiftUI

/// Diff-view settings in the View menu, stored in UserDefaults so open diffs follow them live,
/// and the review commands for the frontmost PR's shown file.
struct DiffCommands: Commands {
    @AppStorage(DiffSettings.wrapLinesKey) private var wrapLines = DiffSettings.wrapLinesDefault
    private let windows = ReviewWindows.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Wrap Lines", isOn: $wrapLines)
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
        CommandMenu("Review") {
            let tab = windows.keyTab
            Button("Mark Viewed and Show Next File") {
                if let tab { Task { await tab.markViewedAndAdvance() } }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(tab?.selectedFile == nil)
            // ⇧V and ] work too, but only through `ReviewWindows`' key monitor: as menu
            // shortcuts they would take those keys from every text field.
            Button("Toggle Viewed (⇧V)") {
                if let tab, let path = tab.selectedFile { Task { await tab.toggleViewed(path: path) } }
            }
            .disabled(tab?.selectedFile == nil)
        }
    }
}

enum DiffSettings {
    static let wrapLinesKey = "wrapLines"
    static let wrapLinesDefault = true
}

/// Which PR each window shows, and so which PR the review keys act on: the key window's.
/// ⌘↓ and `]` mark the shown file viewed and show the next one, and ⇧V toggles it, unless the
/// focus is somewhere text can be typed.
@Observable
@MainActor
final class ReviewWindows {
    static let shared = ReviewWindows()

    /// The PR in the key window, if that's a PR's window.
    private(set) var keyTab: PullRequestTab?
    @ObservationIgnored private let tabs = NSMapTable<NSWindow, PullRequestTab>.weakToStrongObjects()

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.keyTab = window.flatMap { self?.tabs.object(forKey: $0) } }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread, where the event came from.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
    }

    func register(_ tab: PullRequestTab, for window: NSWindow) {
        tabs.setObject(tab, forKey: window)
        if window.isKeyWindow { keyTab = tab }
    }

    /// Whether `event` was a review key, now acted on.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, let tab = tabs.object(forKey: window),
              let path = tab.selectedFile, !isTyping(in: window)
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
}

/// Reports the window the view is in once it has one.
struct WindowReader: NSViewRepresentable {
    let found: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.found = found
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class WindowReportingView: NSView {
    var found: @MainActor (NSWindow) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { found(window) }
    }
}

/// Whether the focus is in a field or editor that takes typing, such as the find bar.
@MainActor
private func isTyping(in window: NSWindow) -> Bool {
    guard let text = window.firstResponder as? NSTextView else { return false }
    return text.isEditable
}
