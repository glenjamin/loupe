import Foundation

/// A selection in a comment quoted into a reply as github.com's `r` does: the selected text
/// written back as markdown, every line marked `> `, then a blank line to write after.
public enum QuoteReply {
    /// The markdown for a selection in a comment GitHub rendered, from the selected HTML with
    /// the elements it's inside around it.
    public static func markdown(fromHTML html: String) -> String {
        markdown(CommentBlock.blocks(fromHTML: html))
    }

    /// The markdown for the characters `range` (in UTF-16) selects in one block's `text` of a
    /// comment shown natively from `blocks`, or nil if no block has that text. A selection from
    /// a list item's start keeps its marker and depth, and one inside a quote stays quoted.
    public static func markdown(selecting range: NSRange, of text: String, in blocks: [CommentBlock]) -> String? {
        guard range.length > 0, let found = block(withText: text, in: blocks),
              let selected = Range(range, in: text) else { return nil }
        let part: CommentBlock
        switch found.block {
        case let .code(code):
            part = .code(String(code[selected]))
        case let .text(attributed, indent):
            guard let lower = AttributedString.Index(selected.lowerBound, within: attributed),
                  let upper = AttributedString.Index(selected.upperBound, within: attributed) else { return nil }
            part = .text(AttributedString(attributed[lower..<upper]), indent: range.location == 0 ? indent : 0)
        case .quote, .rule:
            return nil
        }
        let wrapped = (0..<found.depth).reduce(part) { inner, _ in .quote([inner]) }
        return markdown([wrapped])
    }

    /// `markdown` as a quote, each line marked, ending in a blank line; empty for nothing but
    /// whitespace.
    public static func quoted(_ markdown: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n") + "\n\n"
    }

    /// `text` with `quote` after it, a blank line apart, as github.com adds a second quote to a
    /// reply already being written.
    public static func appending(_ quote: String, to text: String) -> String {
        var base = Substring(text)
        while let last = base.last, last.isWhitespace { base.removeLast() }
        return base.isEmpty ? quote : base + "\n\n" + quote
    }

    /// Blocks as markdown: a blank line between them, and none between items of a list.
    static func markdown(_ blocks: [CommentBlock]) -> String {
        var written = ""
        var lastWasItem = false
        for block in blocks {
            let isItem = if case let .text(text, _) = block { isListItem(String(text.characters)) } else { false }
            let markdown = self.markdown(block)
            guard !markdown.isEmpty else { continue }
            if !written.isEmpty { written += isItem && lastWasItem ? "\n" : "\n\n" }
            written += markdown
            lastWasItem = isItem
        }
        return written
    }

    private static func markdown(_ block: CommentBlock) -> String {
        switch block {
        case let .text(text, indent):
            var line = inline(text)
            // The bullet `CommentBlock` draws for an unordered item, and its task box.
            if line.hasPrefix("• ") { line = "- " + line.dropFirst(2) }
            for (box, written) in [("☐ ", "[ ] "), ("☑ ", "[x] ")] where line.hasPrefix("- \(box)") {
                line = "- " + written + line.dropFirst(2 + box.count)
            }
            return String(repeating: "  ", count: indent) + line
        case let .code(code):
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: code) + 1))
            return "\(fence)\n\(code)\n\(fence)"
        case let .quote(inner):
            let written = markdown(inner)
            return written.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
        case .rule:
            return "---"
        }
    }

    /// Inline text as markdown: links, then code, bold, italic and struck-through runs within
    /// them.
    private static func inline(_ text: AttributedString) -> String {
        var written = ""
        for (link, range) in text.runs[\.link] {
            var inner = ""
            for run in text[range].runs {
                inner += styled(String(text[run.range].characters), run.inlinePresentationIntent ?? [])
            }
            guard let link else {
                written += inner
                continue
            }
            let plain = String(text[range].characters)
            if plain == link.absoluteString || plain.hasPrefix("@") || plain.hasPrefix("#") {
                // A bare URL, a mention or a reference, which GitHub links again by itself.
                written += plain
            } else if plain.hasPrefix("["), plain.hasSuffix("]") {
                // An image, which `CommentBlock` shows as its alt text linked to itself.
                written += "![\(plain.dropFirst().dropLast())](\(link.absoluteString))"
            } else {
                written += "[\(inner)](\(link.absoluteString))"
            }
        }
        return written
    }

    /// A run's text marked with its styles, the markers kept inside any spaces at its ends.
    private static func styled(_ text: String, _ intent: InlinePresentationIntent) -> String {
        if intent.contains(.code) {
            let ticks = String(repeating: "`", count: longestRun(of: "`", in: text) + 1)
            let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
            return ticks + pad + text + pad + ticks
        }
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        var marked = core
        if intent.contains(.strikethrough) { marked = "~~\(marked)~~" }
        if intent.contains(.emphasized) { marked = "_\(marked)_" }
        if intent.contains(.stronglyEmphasized) { marked = "**\(marked)**" }
        let leading = text.prefix { $0.isWhitespace }
        let trailing = String(text.reversed().prefix { $0.isWhitespace })
        return leading + marked + trailing
    }

    private static func isListItem(_ text: String) -> Bool {
        text.hasPrefix("• ") || text.prefixMatch(of: #/\d+\. /#) != nil
    }

    /// The block whose text is `text`, depth first, and how many quotes it's inside.
    private static func block(withText text: String, in blocks: [CommentBlock], depth: Int = 0) -> (block: CommentBlock, depth: Int)? {
        for block in blocks {
            switch block {
            case let .text(attributed, _) where String(attributed.characters) == text:
                return (block, depth)
            case let .code(code) where code == text:
                return (block, depth)
            case let .quote(inner):
                if let found = self.block(withText: text, in: inner, depth: depth + 1) { return found }
            default:
                continue
            }
        }
        return nil
    }

    private static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0, current = 0
        for each in text {
            current = each == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
