import AppKit
import LoupeInbox
import SwiftUI

/// The lists' search: whether its field is shown, and asking for the focus in it. What's typed
/// is the lists model's, which narrows them. The field shows on ⌘F; Esc clears it and goes back
/// to the list, and Esc with nothing typed, or leaving it emptied, hides it.
@Observable
@MainActor
final class ListSearch {
    let lists: PullRequestListModel
    private(set) var isShown = false
    /// Bumped to put the focus in the field, its text selected.
    private(set) var focusRequests = 0

    init(lists: PullRequestListModel) {
        self.lists = lists
    }

    /// Shows the field, or selects what's in it, with the focus there.
    func find() {
        isShown = true
        focusRequests += 1
    }

    /// Esc, in the field or the list: clears what's typed, or hides the field if there's
    /// nothing to clear. Whether there was a search to act on.
    func escape() -> Bool {
        guard isShown else { return false }
        if lists.searchText.isEmpty { hide() } else { lists.searchText = "" }
        return true
    }

    func hide() {
        lists.searchText = ""
        isShown = false
    }
}

/// The lists' toolbar item: the search field while searching, otherwise a button that shows it,
/// as AppKit's own search toolbar item folds away when idle.
struct ListSearchToolbarItem: View {
    let search: ListSearch

    var body: some View {
        if search.isShown {
            ListSearchField(search: search)
                .frame(width: 240)
        } else {
            Button("Search", systemImage: "magnifyingglass") { search.find() }
                .help("Search the pull requests (⌘F)")
        }
    }
}

/// An `NSSearchField` on the lists model's search text. ↓ moves into the list, selecting its
/// first row if none is, and Esc goes to `ListSearch.escape`, then back to the list.
private struct ListSearchField: NSViewRepresentable {
    let search: ListSearch

    func makeNSView(context: Context) -> FocusingSearchField {
        let field = FocusingSearchField()
        field.placeholderString = "Title, repo, #number, author, branch"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search pull requests")
        return field
    }

    func updateNSView(_ field: FocusingSearchField, context: Context) {
        context.coordinator.search = search
        if field.stringValue != search.lists.searchText { field.stringValue = search.lists.searchText }
        if context.coordinator.focusRequests != search.focusRequests {
            context.coordinator.focusRequests = search.focusRequests
            field.focusWhenInWindow()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(search: search)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var search: ListSearch
        var focusRequests = 0
        /// Set while the focus is moved to the list from here, which isn't leaving the field.
        private var isHandingOver = false

        init(search: ListSearch) {
            self.search = search
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            search.lists.searchText = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                _ = search.escape()
                focusList(from: control, selectingFirst: false)
                return true
            case #selector(NSResponder.moveDown(_:)):
                focusList(from: control, selectingFirst: true)
                return true
            default:
                return false
            }
        }

        /// Leaving the field emptied hides it, as a search toolbar item folds away. AppKit says
        /// editing ended only after an edit, so leaving it untouched keeps it.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isHandingOver, search.lists.searchText.isEmpty else { return }
            search.hide()
        }

        private func focusList(from control: NSControl, selectingFirst: Bool) {
            guard let window = control.window, let table = firstList(in: window) else { return }
            isHandingOver = true
            window.makeFirstResponder(table)
            isHandingOver = false
            if selectingFirst, table.selectedRow < 0, let down = downArrow(in: window) {
                table.keyDown(with: down)
            }
        }
    }
}

/// A search field that takes the focus once it's in a window, as it's made only when shown.
final class FocusingSearchField: NSSearchField {
    private var wantsFocus = false

    func focusWhenInWindow() {
        wantsFocus = true
        if window != nil { Task { @MainActor in self.takeFocus() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus, window != nil { Task { @MainActor in self.takeFocus() } }
    }

    private func takeFocus() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
}

/// The first list shown in the window with rows in it: Mine's, unless nothing in it matches.
@MainActor
private func firstList(in window: NSWindow) -> NSTableView? {
    guard let root = window.contentView else { return nil }
    return allDescendants(of: root).lazy.compactMap { $0 as? NSTableView }.first { !$0.isHiddenOrHasHiddenAncestor && $0.numberOfRows > 0 }
}

@MainActor
private func allDescendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + allDescendants(of: $0) }
}

/// ↓, as the keyboard sends it, for a list to move its selection by.
@MainActor
private func downArrow(in window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125
    )
}
