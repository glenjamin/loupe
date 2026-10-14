import AppKit
import LoupeCore
import LoupeInbox
import SwiftUI
import WebKit

/// A markdown file's choice between its diff and GitHub's rendering of it, and that rendering.
struct MarkdownPreview {
    let source: MarkdownSource
    let isRendered: Bool
    let setRendered: (Bool) -> Void
    /// Nil until asked for.
    let rendering: MarkdownRendering?
    /// Asks for the rendering, unless it's done or underway; tries again after a failure.
    let render: () async -> Void
    /// The web view it's shown in, made when first needed.
    let page: () -> MarkdownPage
}

/// The file as GitHub renders it, with progress while it's rendered and why it failed if so.
struct RenderedMarkdownView: View {
    let preview: MarkdownPreview

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            switch preview.rendering {
            case .rendering, nil:
                ProgressView("Rendering…")
            case let .ready(html):
                MarkdownWebView(page: preview.page(), source: preview.source, html: html)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn't render \((preview.source.path as NSString).lastPathComponent)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Retry") { Task { await preview.render() } }
                }
            }
        }
        .task(id: preview.source) { await preview.render() }
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let page: MarkdownPage
    let source: MarkdownSource
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        page.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        page.show(html, of: source)
    }
}

/// A PR window's web view for its rendered markdown, showing one file at a time. Made the first
/// time a file is shown rendered and kept while the PR's tab lives, so showing one again only
/// reloads its cached HTML.
@MainActor
final class MarkdownPage: GitHubWebPage {
    private(set) var shown: MarkdownSource?

    private static let pages = NSMapTable<PullRequestTab, MarkdownPage>.weakToStrongObjects()

    static func page(for tab: PullRequestTab) -> MarkdownPage {
        if let page = pages.object(forKey: tab) { return page }
        let page = MarkdownPage()
        pages.setObject(page, forKey: tab)
        return page
    }

    /// The tab's page if a file has ever been shown rendered.
    static func existingPage(for tab: PullRequestTab) -> MarkdownPage? {
        pages.object(forKey: tab)
    }

    /// Loads the page for GitHub's rendering of `source`, unless it's already showing it.
    /// Relative links resolve to the file's neighbours on github.com, at the commit it's from.
    func show(_ html: String, of source: MarkdownSource) {
        guard shown != source else { return }
        shown = source
        // Hidden until loaded, so the last file shown doesn't flash up first.
        webView.alphaValue = 0
        let page = MarkdownHTML.page(html, template: Self.template.html, stylesheet: Self.template.css)
        load(page, baseURL: blobDirectory(of: source))
    }

    override func didFinishLoading() {
        webView.alphaValue = 1
    }
}

extension PullRequestTab {
    /// The Source and Rendered toggle and the rendering for a markdown file; nil for any other.
    func markdownPreview(of file: FileDiff) -> MarkdownPreview? {
        guard let source = markdownSource(of: file) else { return nil }
        let markdown = markdown
        return MarkdownPreview(
            source: source,
            isRendered: markdown.isRendered(file.path),
            setRendered: { markdown.setRendered($0, path: file.path) },
            rendering: markdown.rendering(of: source),
            render: { await self.renderMarkdown(source) },
            page: { MarkdownPage.page(for: self) }
        )
    }
}

/// github.com's view of the directory holding `source`'s file, at its commit.
private func blobDirectory(of source: MarkdownSource) -> URL {
    let directory = source.path.split(separator: "/").dropLast().map(String.init)
    let path = ([source.repository, "blob", source.oid] + directory).joined(separator: "/") + "/"
    return URL(string: "https://github.com/")!.appending(path: path)
}
