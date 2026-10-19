import AppKit
import LoupeCore
import LoupeInbox
import SwiftUI
import WebKit

/// Every markdown box in the app: GitHub's Write and Preview over a `MarkdownTextView`. Preview
/// shows the draft as GitHub renders it, styled as a comment in the conversation, in place of the
/// text, which stays underneath with its selection and keeps the keyboard, so its keys still send
/// and cancel. ⌘⇧P switches between them, as on github.com. A framed box grows with what's
/// written, or with the preview, up to `maxHeight`, then scrolls.
struct MarkdownEditor: View {
    /// The most a framed box grows to, as much as fits by a line in the diff or in a popover.
    static let maxHeight: CGFloat = 400

    @Binding var text: String
    let isEditable: Bool
    /// The PR it's written on, whose repo GitHub resolves mentions and references against.
    let tab: PullRequestTab
    let save: () -> Void
    /// What ⌘⇧↩ does, if anything; without it the key is the text view's own.
    var alternateSave: (() -> Void)?
    let cancel: () -> Void
    var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// The box's least height, framed as a field; without one it fills the space unframed, as a
    /// page.
    var minHeight: CGFloat?
    /// Counts requests to take the focus with the cursor at the end, as after a quote is added,
    /// which shows Write if it's previewing.
    var focusRequests = 0
    @State private var isPreviewing = SnapshotRun.previewsDrafts
    @State private var page = LazyDraftPreviewPage()
    /// How tall the text and the preview's page are laid out, which a framed box grows to fit.
    @State private var writtenHeight: CGFloat = 0
    @State private var previewedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: minHeight == nil ? 0 : 6) {
            if minHeight == nil {
                toggle
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                Divider()
            } else {
                toggle
            }
            ZStack {
                MarkdownTextView(text: $text, isEditable: isEditable, save: save, alternateSave: alternateSave, cancel: cancel, font: font, isPreviewing: isPreviewing, togglePreview: { isPreviewing.toggle() }, focusRequests: focusRequests, contentHeightChanged: minHeight == nil ? nil : { writtenHeight = $0 })
                if isPreviewing {
                    DraftPreview(text: text, tab: tab, page: { page.page(for: tab) }, contentHeightChanged: { previewedHeight = $0 })
                        // Inside the field's border.
                        .padding(minHeight == nil ? 0 : 1)
                }
            }
            .frame(height: boxHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if minHeight != nil {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor))
                }
            }
        }
        .onChange(of: focusRequests, initial: true) { if focusRequests > 0 { isPreviewing = false } }
    }

    /// A framed box's height: the mode's content within its least height and `maxHeight`, a
    /// preview being at its least while it's rendered, empty or failed.
    private var boxHeight: CGFloat? {
        guard let minHeight else { return nil }
        let content: CGFloat = switch (isPreviewing, tab.markdown.preview(ofDraft: text)) {
        case (false, _): writtenHeight
        // Inside the field's border.
        case (true, .ready?): previewedHeight + 2
        case (true, _): 0
        }
        return min(max(content, minHeight), max(minHeight, Self.maxHeight))
    }

    private var toggle: some View {
        Picker("Mode", selection: $isPreviewing) {
            Text("Write").tag(false)
            Text("Preview").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Write markdown, or preview it as GitHub will show it (⌘⇧P)")
    }
}

/// The draft as GitHub renders it, with a spinner while it's rendered, why it failed if so, and
/// "Nothing to preview" for a blank one, as github.com says.
private struct DraftPreview: View {
    let text: String
    let tab: PullRequestTab
    let page: () -> DraftPreviewPage
    let contentHeightChanged: (CGFloat) -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            switch tab.markdown.preview(ofDraft: text) {
            case nil:
                Text("Nothing to preview")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .rendering?:
                ProgressView().controlSize(.small)
            case let .ready(html)?:
                DraftWebView(page: page(), html: html, contentHeightChanged: contentHeightChanged)
            case let .failed(message)?:
                VStack(spacing: 6) {
                    Label("Couldn't render the preview", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.diffDanger)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(message)
                    Button("Retry") { Task { await tab.renderDraft(text) } }
                        .controlSize(.small)
                }
                .font(.callout)
                .padding(8)
            }
        }
        .task(id: text) { await tab.renderDraft(text) }
    }
}

private struct DraftWebView: NSViewRepresentable {
    let page: DraftPreviewPage
    let html: String
    let contentHeightChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> WKWebView {
        page.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        page.contentHeightChanged = contentHeightChanged
        page.show(html)
    }
}

/// One box's web view for its preview, made the first time it previews and kept with the box, so
/// previewing the same text again doesn't reload it.
@MainActor
final class DraftPreviewPage: GitHubWebPage {
    /// Told how tall the page's content is whenever that changes, as it loads or is rewrapped.
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
    private var shown: String?

    override init() {
        super.init()
        // In a world of the app's own, as the page runs no script of its own.
        let world = WKContentWorld.world(name: "LoupeDraftPreview")
        let controller = webView.configuration.userContentController
        controller.add(ContentHeightHandler(page: self), contentWorld: world, name: contentHeightMessage)
        controller.addUserScript(WKUserScript(source: reportsContentHeight, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
    }

    /// Loads the page for GitHub's rendering of a draft, unless it's already showing it.
    func show(_ html: String) {
        guard shown != html else { return }
        shown = html
        // Hidden until loaded, so the last rendering doesn't flash up first.
        webView.alphaValue = 0
        load(MarkdownHTML.draftPage(html, template: Self.template.html, stylesheet: Self.template.css), baseURL: URL(string: "https://github.com/")!)
    }

    override func didFinishLoading() {
        webView.alphaValue = 1
    }

    override class func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        UnfocusedWebView(frame: .zero, configuration: configuration)
    }
}

/// Makes a box's preview page when it's first needed, as most boxes are never previewed.
@MainActor
private final class LazyDraftPreviewPage {
    private var made: DraftPreviewPage?

    func page(for tab: PullRequestTab) -> DraftPreviewPage {
        if let made { return made }
        let page = DraftPreviewPage()
        page.openPullRequestLink = { [weak tab] in await tab?.open($0) }
        made = page
        return page
    }
}

/// Passes the page's content height on, holding the page weakly, as the web view holds this.
private final class ContentHeightHandler: NSObject, WKScriptMessageHandler {
    weak var page: DraftPreviewPage?

    init(page: DraftPreviewPage) {
        self.page = page
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let height = message.body as? Double else { return }
        MainActor.assumeIsolated { page?.contentHeightChanged(ceil(height)) }
    }
}

/// A web view that's clicked and scrolled without taking the keyboard, which stays with the text
/// under the preview.
final class UnfocusedWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
}

private let contentHeightMessage = "contentHeight"

/// Reports the height of the draft's content, the page's `main`, now and whenever it changes.
private let reportsContentHeight = """
    (() => {
      const main = document.querySelector('main');
      if (!main) return;
      new ResizeObserver(() => webkit.messageHandlers.\(contentHeightMessage).postMessage(main.getBoundingClientRect().height)).observe(main);
    })()
    """
