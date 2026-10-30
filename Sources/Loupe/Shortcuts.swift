import AppKit
import SwiftUI

/// Every keyboard shortcut: the menus bind theirs from here, the review keys' monitor matches
/// the plain keys, and the shortcuts panel lists them all, so none can be missing from it.
enum Shortcut: CaseIterable {
    case showShortcuts, showLists, selectTab, selectLastTab, previousTab, nextTab, closeTab, closeAllTabs
    case find, findNext, findPrevious, refresh
    case openSelected, toggleTodo, showClosed
    case conversation, files, visualReview, circleCI, terraform
    case openOnGitHub, copyLink, openInEditor, editDescription, reviewers, merge
    case summary, approve, requestChanges, submitReview
    case nextFile, previousFile, markReviewedAndNext, toggleReviewed, nextCommit, previousCommit
    case toggleRendered, hideRevealedLines, hideWhitespace, wrapLines, quoteReply
    case send, sendSecond, cancel, togglePreview, suggestChange, moveByCodeWord

    enum Group: String, CaseIterable {
        case anywhere = "Anywhere"
        case lists = "Pull request lists"
        case pullRequest = "Pull request"
        case review = "Review"
        case files = "Files"
        case comments = "Comment boxes"
    }

    var group: Group {
        switch self {
        case .showShortcuts, .showLists, .selectTab, .selectLastTab, .previousTab, .nextTab, .closeTab, .closeAllTabs, .find, .findNext, .findPrevious, .refresh: .anywhere
        case .openSelected, .toggleTodo, .showClosed: .lists
        case .conversation, .files, .visualReview, .circleCI, .terraform, .openOnGitHub, .copyLink, .openInEditor, .editDescription, .reviewers, .merge: .pullRequest
        case .summary, .approve, .requestChanges, .submitReview: .review
        case .nextFile, .previousFile, .markReviewedAndNext, .toggleReviewed, .nextCommit, .previousCommit, .toggleRendered, .hideRevealedLines, .hideWhitespace, .wrapLines, .quoteReply: .files
        case .send, .sendSecond, .cancel, .togglePreview, .suggestChange, .moveByCodeWord: .comments
        }
    }

    /// What it does, as the panel lists it.
    var title: String {
        switch self {
        case .showShortcuts: "Show keyboard shortcuts"
        case .showLists: "Show the pull request lists"
        case .selectTab: "Show a PR tab by position"
        case .selectLastTab: "Show the last PR tab"
        case .previousTab: "Previous tab"
        case .nextTab: "Next tab"
        case .closeTab: "Close the tab"
        case .closeAllTabs: "Close all tabs"
        case .find: "Search the lists, or find in a PR"
        case .findNext: "Find next"
        case .findPrevious: "Find previous"
        case .refresh: "Refresh the lists, or reload the PR"
        case .openSelected: "Open the selected PR"
        case .toggleTodo: "Switch between the lists and TODO"
        case .showClosed: "Show closed and merged"
        case .conversation: "Conversation"
        case .files: "Files changed"
        case .visualReview: "Visual review"
        case .circleCI: "Failed CircleCI jobs"
        case .terraform: "Terraform Cloud's plans"
        case .openOnGitHub: "Open on GitHub"
        case .copyLink: "Copy the PR's link"
        case .openInEditor: "Check out and open in the editor"
        case .editDescription: "Edit the description"
        case .reviewers: "Ask for reviews"
        case .merge: "Merge, once confirmed"
        case .summary: "Write the review's summary"
        case .approve: "Approve, once confirmed"
        case .requestChanges: "Request changes, once confirmed"
        case .submitReview: "Submit the review, once confirmed"
        case .nextFile: "Next file"
        case .previousFile: "Previous file"
        case .markReviewedAndNext: "Mark reviewed and show the next file"
        case .toggleReviewed: "Toggle reviewed"
        case .nextCommit: "Next commit"
        case .previousCommit: "Previous commit, back to all changes"
        case .toggleRendered: "Switch between the diff and the rendered file"
        case .hideRevealedLines: "Hide the lines revealed around the hunks"
        case .hideWhitespace: "Hide whitespace changes"
        case .wrapLines: "Wrap lines"
        case .quoteReply: "Quote the selected text into a reply"
        case .send: "Send"
        case .sendSecond: "Send by the second button, as starting a review"
        case .cancel: "Cancel"
        case .togglePreview: "Switch between Write and Preview"
        case .suggestChange: "Suggest a change to the lines"
        case .moveByCodeWord: "Move by code words"
        }
    }

    /// The menu item's key equivalent, for those the menus bind.
    var menuKey: KeyboardShortcut? {
        switch self {
        case .showLists: KeyboardShortcut("1")
        case .selectLastTab: KeyboardShortcut("9")
        case .previousTab: KeyboardShortcut("[", modifiers: [.command, .shift])
        case .nextTab: KeyboardShortcut("]", modifiers: [.command, .shift])
        case .closeTab: KeyboardShortcut("w")
        case .closeAllTabs: KeyboardShortcut("w", modifiers: [.command, .option])
        case .find: KeyboardShortcut("f")
        case .findNext: KeyboardShortcut("g")
        case .findPrevious: KeyboardShortcut("g", modifiers: [.command, .shift])
        case .refresh: KeyboardShortcut("r")
        case .toggleTodo: KeyboardShortcut("t", modifiers: [.command, .control])
        case .showClosed: KeyboardShortcut("c", modifiers: [.command, .control])
        // ⌃ rather than ⌘, which picks the PR tab by number.
        case .conversation: KeyboardShortcut("1", modifiers: .control)
        case .files: KeyboardShortcut("2", modifiers: .control)
        case .visualReview: KeyboardShortcut("3", modifiers: .control)
        case .circleCI: KeyboardShortcut("4", modifiers: .control)
        case .terraform: KeyboardShortcut("5", modifiers: .control)
        case .openOnGitHub: KeyboardShortcut("o", modifiers: [.command, .shift])
        case .copyLink: KeyboardShortcut("c", modifiers: [.command, .shift])
        case .openInEditor: KeyboardShortcut("e", modifiers: [.command, .shift])
        case .editDescription: KeyboardShortcut("e", modifiers: [.command, .option])
        case .reviewers: KeyboardShortcut("r", modifiers: [.command, .option])
        case .merge: KeyboardShortcut("m", modifiers: [.command, .shift])
        case .summary: KeyboardShortcut("s", modifiers: [.command, .option])
        case .approve: KeyboardShortcut("a", modifiers: [.command, .option])
        case .requestChanges: KeyboardShortcut("x", modifiers: [.command, .option])
        case .submitReview: KeyboardShortcut(.return, modifiers: [.command, .option])
        case .markReviewedAndNext: KeyboardShortcut(.downArrow, modifiers: .command)
        case .toggleRendered: KeyboardShortcut("r", modifiers: [.command, .control])
        case .hideRevealedLines: KeyboardShortcut("e", modifiers: [.command, .control])
        case .hideWhitespace: KeyboardShortcut("h", modifiers: [.command, .control])
        case .wrapLines: KeyboardShortcut("l", modifiers: [.command, .option])
        default: nil
        }
    }

    /// The key, without ⌘, ⌥ or ⌃, that the review keys' monitor acts on while no text can be
    /// typed, as typed: a capital needs ⇧. Menu shortcuts would take these from every text field.
    var plainKey: String? {
        switch self {
        case .showShortcuts: "?"
        case .nextFile: "j"
        case .previousFile: "k"
        case .markReviewedAndNext: "]"
        case .toggleReviewed: "V"
        case .nextCommit: "."
        case .previousCommit: ","
        case .quoteReply: "r"
        default: nil
        }
    }

    /// The keys as the panel shows them.
    var keys: [String] {
        switch self {
        case .selectTab: ["⌘2–⌘8"]
        case .previousTab: ["⇧⌘[", "⌃⇧⇥"]
        case .nextTab: ["⇧⌘]", "⌃⇥"]
        case .openSelected: ["↩"]
        case .send: ["⌘↩"]
        case .sendSecond: ["⇧⌘↩"]
        case .cancel: ["esc"]
        case .togglePreview: ["⇧⌘P"]
        case .suggestChange: ["⌘G"]
        case .moveByCodeWord: ["⌥←", "⌥→"]
        default: [plainKey.map(Self.symbol(forPlainKey:)), menuKey.map(Self.symbol(for:))].compactMap { $0 }
        }
    }

    /// Whether `event` is this shortcut's plain key.
    func matches(_ event: NSEvent) -> Bool {
        guard let plainKey, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        return event.characters == plainKey
    }

    private static func symbol(forPlainKey key: String) -> String {
        key.uppercased() == key && key.lowercased() != key ? "⇧\(key)" : key
    }

    private static func symbol(for shortcut: KeyboardShortcut) -> String {
        let modifiers = shortcut.modifiers
        let symbols: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let key = switch shortcut.key {
        case .return: "↩"
        case .downArrow: "↓"
        case .upArrow: "↑"
        default: String(shortcut.key.character).uppercased()
        }
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }
}

extension View {
    /// Binds `shortcut`'s menu key, if it has one.
    @ViewBuilder
    func keyboardShortcut(_ shortcut: Shortcut) -> some View {
        if let key = shortcut.menuKey {
            keyboardShortcut(key)
        } else {
            self
        }
    }
}

/// Every shortcut, by where it works, in a sheet over the window that ↩ or ⎋ closes.
@MainActor
enum ShortcutsPanel {
    static func show(in window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ShortcutsList { [weak window] in
            if let window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        }))
        window.beginSheet(sheet)
    }
}

private struct ShortcutsList: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            HStack(alignment: .top, spacing: 32) {
                column([.anywhere, .lists, .pullRequest])
                column([.review, .files, .comments])
            }
            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
            // Esc closes it too.
            Button("", action: close)
                .keyboardShortcut(.cancelAction)
                .hidden()
                .frame(width: 0, height: 0)
        }
        .padding(20)
        .accessibilityIdentifier("keyboard-shortcuts")
    }

    /// One grid for the column, so every group's descriptions start in line.
    private func column(_ groups: [Shortcut.Group]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(groups, id: \.self) { group in
                GridRow {
                    Text(group.rawValue)
                        .font(.headline)
                        .padding(.top, group == groups.first ? 0 : 10)
                        .gridCellColumns(2)
                }
                ForEach(Shortcut.allCases.filter { $0.group == group }, id: \.self) { shortcut in
                    GridRow {
                        HStack(spacing: 4) {
                            ForEach(shortcut.keys, id: \.self, content: Keycap.init)
                        }
                        .gridColumnAlignment(.trailing)
                        Text(shortcut.title)
                    }
                }
            }
        }
        .frame(width: 400, alignment: .leading)
    }
}

/// A key or chord drawn as a key on a keyboard, so a lone `.` or `,` is as easy to read as ⌘F.
private struct Keycap: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .frame(minWidth: 14)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary, lineWidth: 0.5))
    }
}
