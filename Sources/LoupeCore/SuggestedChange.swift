import Foundation

/// github.com's "Add a suggestion": a `suggestion` block holding the commented lines as they are
/// on the new side, which the reviewer edits into the change they propose.
public enum SuggestedChange {
    /// Puts a suggestion of `lines` in place of `selection` (in UTF-16) in a comment's `text`,
    /// on lines of its own, with the cursor at the end of the lines inside the block.
    public static func insertion(of lines: [String], into text: String, replacing selection: NSRange) -> TextEdit {
        let whole = text as NSString
        let before = whole.substring(to: selection.location)
        let after = whole.substring(from: NSMaxRange(selection))
        let opening = (before.isEmpty || before.hasSuffix("\n") ? "" : "\n") + "```suggestion\n"
        let body = lines.joined(separator: "\n")
        let closing = "\n```" + (after.isEmpty || after.hasPrefix("\n") ? "" : "\n")
        let cursor = selection.location + (opening + body).utf16.count
        return TextEdit(range: selection, replacement: opening + body + closing, selection: NSRange(location: cursor, length: 0))
    }
}

/// A change to a text box's text: what replaces which range, in UTF-16, and the selection after.
public struct TextEdit: Sendable, Equatable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// `text` with the edit made.
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}
