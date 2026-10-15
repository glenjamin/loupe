import Foundation

/// A comment's body as blocks of text to show natively, from the HTML GitHub renders it to:
/// paragraphs with bold, italic, code and links inline, code blocks, quotes and rules. Images
/// become links to themselves, so nothing is fetched to show a comment.
public enum CommentBlock: Sendable, Equatable {
    /// A paragraph, heading, list item or table row, indented by list depth.
    case text(AttributedString, indent: Int)
    case code(String)
    case quote([CommentBlock])
    case rule

    /// The blocks of GitHub's `bodyHTML` for a comment.
    public static func blocks(fromHTML html: String) -> [CommentBlock] {
        var reader = HTMLReader(html)
        var builder = BlockBuilder()
        while let token = reader.next() {
            builder.add(token)
        }
        return builder.finish()
    }
}

/// Builds blocks from HTML tokens, keeping the inline styles and the lists and quotes open.
private struct BlockBuilder {
    private var inline = AttributedString()
    private var styles: [String] = []
    private var links: [URL?] = []
    private var lists: [(ordered: Bool, count: Int)] = []
    /// The blocks of each open quote, innermost last; the first is the comment's own.
    private var containers: [[CommentBlock]] = [[]]
    /// Text inside `<pre>`, kept as it is, until it closes.
    private var preformatted: String?
    /// How deep inside an element whose content isn't shown, such as `<svg>`.
    private var skipping = 0
    /// Whether the current table row has had a cell yet.
    private var rowHasCell = false

    mutating func add(_ token: HTMLToken) {
        switch token {
        case let .text(text):
            guard skipping == 0 else { return }
            if preformatted != nil {
                preformatted? += text
            } else {
                appendInline(text)
            }
        case let .open(name, attributes, selfClosing):
            if skipping > 0 || Self.skipped.contains(name) {
                if !selfClosing && !Self.void.contains(name) { skipping += 1 }
                return
            }
            open(name, attributes)
            if selfClosing && !Self.void.contains(name) { close(name) }
        case let .close(name):
            if skipping > 0 {
                skipping -= 1
                return
            }
            close(name)
        }
    }

    mutating func finish() -> [CommentBlock] {
        flush()
        while containers.count > 1 { closeQuote() }
        return containers[0]
    }

    private mutating func open(_ name: String, _ attributes: [String: String]) {
        if let preformatted {
            // Inside a code block only line breaks matter.
            if name == "br" { self.preformatted = preformatted + "\n" }
            return
        }
        switch name {
        case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "details", "summary", "table", "thead", "tbody", "dl", "dt", "dd":
            flush()
            if name.hasPrefix("h") || name == "summary" { styles.append("strong") }
        case "br":
            inline += AttributedString("\n")
        case "hr":
            flush()
            append(.rule)
        case "pre":
            flush()
            preformatted = ""
        case "blockquote":
            flush()
            containers.append([])
        case "ul", "ol":
            flush()
            lists.append((name == "ol", 0))
        case "li":
            flush()
            guard !lists.isEmpty else { return }
            lists[lists.count - 1].count += 1
            let list = lists[lists.count - 1]
            inline += AttributedString(list.ordered ? "\(list.count). " : "• ")
        case "tr":
            flush()
            rowHasCell = false
        case "td", "th":
            if rowHasCell { inline += AttributedString("  |  ") }
            rowHasCell = true
            if name == "th" { styles.append("strong") }
        case "strong", "b", "em", "i", "code", "del", "s", "strike", "kbd":
            styles.append(name)
        case "a":
            links.append(attributes["href"].flatMap(Self.absoluteURL))
        case "img":
            let source = attributes["src"].flatMap(Self.absoluteURL)
            let alt = attributes["alt"].flatMap { $0.isEmpty ? nil : $0 } ?? "image"
            var image = AttributedString("[\(alt)]")
            image.link = links.last.flatMap { $0 } ?? source
            inline += image
        case "input" where attributes["type"] == "checkbox":
            inline += AttributedString(attributes["checked"] != nil ? "☑ " : "☐ ")
        default:
            break
        }
    }

    private mutating func close(_ name: String) {
        if preformatted != nil {
            guard name == "pre" else { return }
            var code = preformatted ?? ""
            while code.hasSuffix("\n") { code.removeLast() }
            preformatted = nil
            append(.code(code))
            return
        }
        switch name {
        case "p", "div", "details", "table", "thead", "tbody", "dl", "dt", "dd", "li", "tr":
            flush()
        case "h1", "h2", "h3", "h4", "h5", "h6", "summary":
            flush()
            if let index = styles.lastIndex(of: "strong") { styles.remove(at: index) }
        case "th":
            if let index = styles.lastIndex(of: "strong") { styles.remove(at: index) }
        case "blockquote":
            flush()
            if containers.count > 1 { closeQuote() }
        case "ul", "ol":
            flush()
            if !lists.isEmpty { lists.removeLast() }
        case "strong", "b", "em", "i", "code", "del", "s", "strike", "kbd":
            if let index = styles.lastIndex(of: name) { styles.remove(at: index) }
        case "a":
            if !links.isEmpty { links.removeLast() }
        default:
            break
        }
    }

    /// Adds text with the open styles, its runs of whitespace collapsed to one space as HTML
    /// shows them, and none at the start of a block.
    private mutating func appendInline(_ text: String) {
        var collapsed = ""
        var lastWasSpace = inline.characters.last.map { $0 == " " || $0 == "\n" } ?? true
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { collapsed.append(" ") }
                lastWasSpace = true
            } else {
                collapsed.append(character)
                lastWasSpace = false
            }
        }
        guard !collapsed.isEmpty else { return }
        var run = AttributedString(collapsed)
        var intent: InlinePresentationIntent = []
        for style in styles {
            switch style {
            case "strong", "b": intent.insert(.stronglyEmphasized)
            case "em", "i": intent.insert(.emphasized)
            case "code", "kbd": intent.insert(.code)
            case "del", "s", "strike": intent.insert(.strikethrough)
            default: break
            }
        }
        if !intent.isEmpty { run.inlinePresentationIntent = intent }
        if let link = links.last.flatMap({ $0 }) { run.link = link }
        inline += run
    }

    /// Ends the paragraph being built, if it has any text.
    private mutating func flush() {
        var text = inline
        inline = AttributedString()
        while let last = text.characters.last, last == " " || last == "\n" {
            text.characters.removeLast()
        }
        guard !text.characters.isEmpty else { return }
        append(.text(text, indent: max(0, lists.count - 1)))
    }

    private mutating func append(_ block: CommentBlock) {
        containers[containers.count - 1].append(block)
    }

    private mutating func closeQuote() {
        let quoted = containers.removeLast()
        if !quoted.isEmpty { append(.quote(quoted)) }
    }

    /// Elements whose content is never shown.
    static let skipped: Set<String> = ["svg", "style", "script", "template", "head"]
    /// Elements with no closing tag.
    static let void: Set<String> = ["br", "hr", "img", "input", "meta", "link", "source", "wbr", "col", "area", "base", "embed", "param", "track"]

    /// A link as GitHub writes it, made absolute where it's relative to github.com.
    static func absoluteURL(_ href: String) -> URL? {
        if href.hasPrefix("/") { return URL(string: "https://github.com" + href) }
        return URL(string: href)
    }
}

private enum HTMLToken {
    case text(String)
    case open(String, [String: String], selfClosing: Bool)
    case close(String)
}

/// Splits HTML into tags and text, with entities decoded. Comments and doctypes are dropped.
private struct HTMLReader {
    private let html: [Character]
    private var index = 0

    init(_ html: String) {
        self.html = Array(html)
    }

    mutating func next() -> HTMLToken? {
        while index < html.count {
            if html[index] == "<", let tag = readTag() {
                if let tag { return tag }
                continue
            }
            let start = index
            index += 1
            while index < html.count, html[index] != "<" { index += 1 }
            return .text(decodeEntities(String(html[start..<index])))
        }
        return nil
    }

    /// The tag at `<`, nil inside for a comment or doctype that was skipped, or nil outside when
    /// the `<` doesn't start a tag and is text.
    private mutating func readTag() -> HTMLToken?? {
        guard let end = html[index...].firstIndex(of: ">") else { return nil }
        let inner = String(html[(index + 1)..<end])
        if inner.hasPrefix("!--") {
            let rest = String(html[index...])
            if let close = rest.range(of: "-->") {
                index += rest.distance(from: rest.startIndex, to: close.upperBound)
            } else {
                index = html.count
            }
            return .some(nil)
        }
        guard let first = inner.first, first.isLetter || first == "/" || first == "!" else { return nil }
        index = end + 1
        if first == "!" { return .some(nil) }
        if first == "/" {
            return .close(inner.dropFirst().trimmingCharacters(in: .whitespaces).lowercased())
        }
        let selfClosing = inner.hasSuffix("/")
        let body = selfClosing ? String(inner.dropLast()) : inner
        let name = String(body.prefix { !$0.isWhitespace }).lowercased()
        return .open(name, attributes(in: String(body.dropFirst(name.count))), selfClosing: selfClosing)
    }

    private func attributes(in text: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in text.matches(of: /([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/) {
            let value = match.2 ?? match.3 ?? match.4 ?? ""
            attributes[match.1.lowercased()] = decodeEntities(String(value))
        }
        return attributes
    }
}

private func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    return text.replacing(/&(#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);/) { match in
        let entity = match.1
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } ?? String(match.0)
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) } ?? String(match.0)
        }
        return namedEntities[String(entity)] ?? String(match.0)
    }
}

private let namedEntities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]
