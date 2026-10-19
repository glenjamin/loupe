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
        var builder = build(html)
        return builder.finish()
    }

    /// The text of each paragraph and code block of `html`, in order, with where in the HTML
    /// each of its characters came from.
    static func sources(fromHTML html: String) -> [BlockSource] {
        var builder = build(html)
        _ = builder.finish()
        return builder.sources
    }

    private static func build(_ html: String) -> BlockBuilder {
        var reader = HTMLReader(html)
        var builder = BlockBuilder()
        while let token = reader.next() {
            builder.add(token)
        }
        return builder
    }
}

/// A block's text and, for each of its UTF-16 code units, the part of the HTML it shows: the
/// same text in a text node, or the element a character stands for, such as an image's.
struct BlockSource {
    let text: String
    let spans: [SourceSpan]
}

struct SourceSpan: Equatable {
    var start: SourcePoint
    var end: SourcePoint
}

/// A place in the HTML: within a text node, or before or after an element. `node` counts the
/// elements and text nodes from the start, in document order, as a browser's tree has them.
struct SourcePoint: Equatable {
    var node: Int
    /// The UTF-16 offset in a text node, or `before` or `after` the node.
    var offset: Int

    static let before = -1
    static let after = -2
}

/// Builds blocks from HTML tokens, keeping the inline styles and the lists and quotes open.
private struct BlockBuilder {
    /// Each block's text with its sources, in order.
    private(set) var sources: [BlockSource] = []
    private var inline = AttributedString()
    /// Where each UTF-16 unit of `inline` came from, nil for text made here, such as a list's
    /// bullet, which takes the place of what's beside it.
    private var inlineSpans: [SourceSpan?] = []
    private var preformattedSpans: [SourceSpan?] = []
    /// The node the next element or text node will be.
    private var nodeCount = 0
    /// The text node being read, and how many UTF-16 units of it have been, while text runs on
    /// across tokens.
    private var textNode: (index: Int, length: Int)?
    /// Whether the last token opened a `<pre>`, whose first newline isn't part of its text.
    private var justOpenedPre = false
    /// The innermost link, if nothing has been put in it yet, so an image alone in it stands for it.
    private var emptyLink: Int?
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
        let afterPre = justOpenedPre
        justOpenedPre = false
        switch token {
        case var .text(text):
            // A browser drops a newline straight after `<pre>`, and the text node with it if
            // that's all there is.
            if afterPre, text.hasPrefix("\n") { text.removeFirst() }
            guard !text.isEmpty else { return }
            let node = textNode ?? (nodeCount, 0)
            if textNode == nil { nodeCount += 1 }
            textNode = (node.index, node.length + text.utf16.count)
            guard skipping == 0 else { return }
            emptyLink = nil
            if preformatted != nil {
                preformatted? += text
                var offset = node.length
                for character in text {
                    let length = character.utf16.count
                    let span = SourceSpan(start: SourcePoint(node: node.index, offset: offset), end: SourcePoint(node: node.index, offset: offset + length))
                    preformattedSpans += Array(repeating: span, count: length)
                    offset += length
                }
            } else {
                appendInline(text, node: node.index, offset: node.length)
            }
        case let .open(name, attributes, selfClosing):
            let node = nodeCount
            nodeCount += 1
            textNode = nil
            if skipping > 0 || Self.skipped.contains(name) {
                if !selfClosing && !Self.void.contains(name) { skipping += 1 }
                return
            }
            open(name, attributes, node: node)
            justOpenedPre = name == "pre"
            if name != "a" { emptyLink = nil }
            if selfClosing && !Self.void.contains(name) { close(name) }
        case let .close(name):
            textNode = nil
            if skipping > 0 {
                skipping -= 1
                return
            }
            close(name)
        case .other:
            textNode = nil
        }
    }

    mutating func finish() -> [CommentBlock] {
        flush()
        while containers.count > 1 { closeQuote() }
        return containers[0]
    }

    private mutating func open(_ name: String, _ attributes: [String: String], node: Int) {
        let element = SourceSpan(start: SourcePoint(node: node, offset: SourcePoint.before), end: SourcePoint(node: node, offset: SourcePoint.after))
        if let preformatted {
            // Inside a code block only line breaks matter.
            if name == "br" {
                self.preformatted = preformatted + "\n"
                preformattedSpans.append(element)
            }
            return
        }
        switch name {
        case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "details", "summary", "table", "thead", "tbody", "dl", "dt", "dd":
            flush()
            if name.hasPrefix("h") || name == "summary" { styles.append("strong") }
        case "br":
            appendMade("\n", standingFor: element)
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
            appendMade(list.ordered ? "\(list.count). " : "• ")
        case "tr":
            flush()
            rowHasCell = false
        case "td", "th":
            if rowHasCell { appendMade("  |  ") }
            rowHasCell = true
            if name == "th" { styles.append("strong") }
        case "strong", "b", "em", "i", "code", "del", "s", "strike", "kbd":
            styles.append(name)
        case "a":
            links.append(attributes["href"].flatMap(Self.absoluteURL))
            emptyLink = node
        case "img":
            let source = attributes["src"].flatMap(Self.absoluteURL)
            let alt = attributes["alt"].flatMap { $0.isEmpty ? nil : $0 } ?? "image"
            var image = AttributedString("[\(alt)]")
            image.link = links.last.flatMap { $0 } ?? source
            // An image alone in a link, as GitHub puts every one, is selected with its link.
            let shown = emptyLink.map { SourceSpan(start: SourcePoint(node: $0, offset: SourcePoint.before), end: SourcePoint(node: $0, offset: SourcePoint.after)) } ?? element
            inline += image
            inlineSpans += Array(repeating: shown, count: String(image.characters).utf16.count)
        case "input" where attributes["type"] == "checkbox":
            appendMade(attributes["checked"] != nil ? "☑" : "☐", standingFor: element)
            appendMade(" ")
        default:
            break
        }
    }

    private mutating func close(_ name: String) {
        if preformatted != nil {
            guard name == "pre" else { return }
            var code = preformatted ?? ""
            var spans = preformattedSpans
            while code.hasSuffix("\n") {
                code.removeLast()
                spans.removeLast()
            }
            preformatted = nil
            preformattedSpans = []
            sources.append(BlockSource(text: code, spans: Self.resolved(spans)))
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
    private mutating func appendInline(_ text: String, node: Int, offset start: Int) {
        var collapsed = ""
        var spans: [SourceSpan] = []
        var lastWasSpace = inline.characters.last.map { $0 == " " || $0 == "\n" } ?? true
        var offset = start
        var spaceAdded = false
        for character in text {
            let length = character.utf16.count
            let span = SourceSpan(start: SourcePoint(node: node, offset: offset), end: SourcePoint(node: node, offset: offset + length))
            offset += length
            if character.isWhitespace {
                if !lastWasSpace {
                    collapsed.append(" ")
                    spans.append(span)
                    spaceAdded = true
                } else if spaceAdded {
                    // The space shown stands for the whole run.
                    spans[spans.count - 1].end = span.end
                }
                lastWasSpace = true
            } else {
                collapsed.append(character)
                spans += Array(repeating: span, count: length)
                lastWasSpace = false
                spaceAdded = false
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
        inlineSpans += spans
    }

    /// Adds text made here rather than read, such as a bullet, standing for `element` if it
    /// stands for one, or else for what's beside it.
    private mutating func appendMade(_ text: String, standingFor element: SourceSpan? = nil) {
        inline += AttributedString(text)
        inlineSpans += Array(repeating: element, count: text.utf16.count)
    }

    /// Ends the paragraph being built, if it has any text.
    private mutating func flush() {
        var text = inline
        var spans = inlineSpans
        inline = AttributedString()
        inlineSpans = []
        while let last = text.characters.last, last == " " || last == "\n" {
            text.characters.removeLast()
            spans.removeLast()
        }
        guard !text.characters.isEmpty else { return }
        sources.append(BlockSource(text: String(text.characters), spans: Self.resolved(spans)))
        append(.text(text, indent: max(0, lists.count - 1)))
    }

    /// Spans for text made here taken from what's beside it: a selection starting in it starts
    /// at what follows, and one ending in it ends at what's before.
    private static func resolved(_ spans: [SourceSpan?]) -> [SourceSpan] {
        let read = spans.enumerated().compactMap { index, span in span.map { (index, $0) } }
        guard let first = read.first?.1 else { return [] }
        var resolved: [SourceSpan] = []
        var previous: SourceSpan?
        for (index, span) in spans.enumerated() {
            if let span {
                resolved.append(span)
                previous = span
                continue
            }
            let next = read.first { $0.0 > index }?.1
            let start = (next ?? previous ?? first).start
            let end = previous?.end ?? next?.start ?? first.start
            resolved.append(SourceSpan(start: start, end: end))
        }
        return resolved
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
    /// A comment or doctype, which splits the text around it into separate nodes.
    case other
}

/// Splits HTML into tags and text, with entities decoded.
private struct HTMLReader {
    private let html: [Character]
    private var index = 0

    init(_ html: String) {
        self.html = Array(html)
    }

    mutating func next() -> HTMLToken? {
        while index < html.count {
            if html[index] == "<", let tag = readTag() { return tag }
            let start = index
            index += 1
            while index < html.count, html[index] != "<" { index += 1 }
            return .text(decodeEntities(String(html[start..<index])))
        }
        return nil
    }

    /// The tag, comment or doctype at `<`, or nil when the `<` doesn't start one and is text.
    private mutating func readTag() -> HTMLToken? {
        guard let end = html[index...].firstIndex(of: ">") else { return nil }
        let inner = String(html[(index + 1)..<end])
        if inner.hasPrefix("!--") {
            let rest = String(html[index...])
            if let close = rest.range(of: "-->") {
                index += rest.distance(from: rest.startIndex, to: close.upperBound)
            } else {
                index = html.count
            }
            return .other
        }
        guard let first = inner.first, first.isLetter || first == "/" || first == "!" else { return nil }
        index = end + 1
        if first == "!" { return .other }
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
