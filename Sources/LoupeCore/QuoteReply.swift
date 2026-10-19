import Foundation
import WebKit

/// A selection in a comment quoted into a reply as github.com's `r` does: the selected part of
/// GitHub's rendering written back as markdown by github.com's own code, quote-selection, run in
/// WebKit, every line then marked `> ` and a blank line left to write after.
public enum QuoteReply {
    /// `markdown` as github.com quotes it: `> ` before every line, blank ones too, then a blank
    /// line.
    public static func quoted(_ markdown: String) -> String {
        "> " + markdown.components(separatedBy: "\n").joined(separator: "\n> ") + "\n\n"
    }

    /// `text` with `quote` added as github.com adds one to a reply: a blank line after anything
    /// already written, as it is.
    public static func appending(_ quote: String, to text: String) -> String {
        text.isEmpty ? quote : text + "\n\n" + quote
    }

    /// The body of a function for a page of comments, as the conversation's, that quotes the
    /// page's selection: `{ text, thread }`, the markdown of what's selected from where it starts
    /// in a comment's `.body` and the `data-thread-id` of the thread it's in, or null when nothing
    /// is selected or it starts outside a comment. The selection is gone afterwards, as on
    /// github.com.
    public static var selectionScript: String? {
        script.map { $0 + "\nreturn quoteSelection()" }
    }

    /// quote-selection, then github.com's rules around it; nil if the app is missing them.
    static let script: String? = {
        let files = ["quote-selection.js", "quote-reply.js"].map { name in
            bundledResource(name, in: "Loupe_LoupeCore").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        let read = files.compactMap { $0 }
        return read.count == files.count ? read.joined(separator: "\n") : nil
    }()
}

/// Quotes a selection in a comment shown natively, from its blocks, by finding the same selection
/// in GitHub's rendering of it in a web view kept off screen, and quoting that as github.com
/// would.
@MainActor
public final class QuoteConverter: NSObject {
    public static let shared = QuoteConverter()

    private var webView: WKWebView?
    private var isLoaded = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// The markdown for the characters `range` (in UTF-16) selects in the block of the comment
    /// `html` whose text is `text`, as `CommentBlock` shows it; nil if no block has that text or
    /// nothing is selected.
    public func markdown(selecting range: NSRange, of text: String, inComment html: String) async -> String? {
        guard range.length > 0, range.location >= 0,
              let source = CommentBlock.sources(fromHTML: html).first(where: { $0.text == text }),
              NSMaxRange(range) <= source.spans.count
        else { return nil }
        let start = source.spans[range.location].start
        let end = source.spans[NSMaxRange(range) - 1].end
        guard let script = QuoteReply.script else { return nil }
        let view = await loadedView()
        let body = script + "\ndocument.getElementById('source').innerHTML = html\nreturn quoteRange(start, end)"
        let arguments: [String: Any] = ["html": html, "start": [start.node, start.offset], "end": [end.node, end.offset]]
        return try? await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient) as? String
    }

    private func loadedView() async -> WKWebView {
        let view = webView ?? makeView()
        if !isLoaded { await withCheckedContinuation { waiting.append($0) } }
        return view
    }

    private func makeView() -> WKWebView {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.navigationDelegate = self
        webView = view
        // Nothing the comment links to or shows is fetched.
        let page = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            </head><body><div id="source" hidden></div></body></html>
            """
        view.loadHTMLString(page, baseURL: URL(string: "https://github.com/"))
        return view
    }

    private func finishLoading() {
        isLoaded = true
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
    }
}

extension QuoteConverter: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading()
    }
}
