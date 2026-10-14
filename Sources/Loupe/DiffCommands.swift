import SwiftUI

/// Diff-view settings in the View menu, stored in UserDefaults so open diffs follow them live.
struct DiffCommands: Commands {
    @AppStorage(DiffSettings.wrapLinesKey) private var wrapLines = DiffSettings.wrapLinesDefault

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Wrap Lines", isOn: $wrapLines)
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
    }
}

enum DiffSettings {
    static let wrapLinesKey = "wrapLines"
    static let wrapLinesDefault = true
}
