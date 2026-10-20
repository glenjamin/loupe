import AppKit
import LoupeInbox
import LoupeModel
import SwiftUI
import WebKit

/// The header's flag for a PR whose visual baselines differ from its base's: how many, with the
/// stories listed when the pointer rests on it. A click shows the report. Nothing when CI says
/// none differ.
struct VisualReviewBadge: View {
    let tab: PullRequestTab
    let review: VisualReview

    var body: some View {
        if review.hasChanges {
            Button { tab.showVisualReview() } label: {
                HStack(spacing: 3) {
                    Image(systemName: VisualReviewRow.symbol)
                    Text("Visual changes")
                    if let count = review.changeCount {
                        Text(verbatim: "\(count)").monospacedDigit()
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .background(HoverPopoverAnchor(content: VisualReviewPopover(review: review)))
            .accessibilityHint("Shows the visual review report")
        }
    }
}

/// What resting the pointer on the header's flag shows: the counts, each story and how it
/// changed, and how many stories were rendered.
struct VisualReviewPopover: HoverPopoverContent {
    let review: VisualReview
    var onPointerOver: (Bool) -> Void = { _ in }
    var onOpen: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: review.title ?? "Visual review")
                    .font(.headline)
                if let summary = review.summary {
                    Text(verbatim: summary)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if !review.stories.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(review.stories) { story in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: story.name)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(verbatim: story.status.label)
                                    .font(.caption)
                                    .foregroundStyle(story.status.tint)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let rendered = review.rendered {
                Divider()
                Text(verbatim: "\(rendered.count) of \(rendered.total) stories rendered, those that can reach a file this branch changed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 420, alignment: .leading)
        .onHover(perform: onPointerOver)
    }
}

/// The sidebar's row for CI's visual review, under the Conversation row and drawn like it,
/// showing the report in place of the diff while selected.
struct VisualReviewRow: View {
    @Bindable var tab: PullRequestTab
    let review: VisualReview

    static let symbol = "photo.on.rectangle.angled"

    var body: some View {
        let isShown = tab.shownSection == .visualReview
        Button { tab.showVisualReview() } label: {
            HStack(spacing: 4) {
                Label("Visual review", systemImage: Self.symbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let count = review.changeCount {
                    Text(verbatim: "\(count)")
                        .monospacedDigit()
                        .foregroundStyle(isShown ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "Show CI's visual review report (⌃3)\(review.summary.map { ": \($0)" } ?? "")"))
        .accessibilityAddTraits(isShown ? .isSelected : [])
        .background(VisualReviewRowMarker())
        .foregroundStyle(isShown ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isShown ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        // Sits right under the Conversation row, whose own padding spaces them.
        .padding([.horizontal, .bottom], 8)
    }
}

/// The report beside the sidebar: a bar saying what it is with ways out to the browser, over
/// the report's own page, covered by a native wait until it has loaded or by why it couldn't.
struct VisualReviewPane: View {
    let page: VisualReviewPage
    let review: VisualReview
    let isShown: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            VisualReviewWebView(page: page, review: review, isShown: isShown, isCovered: page.cover != nil)
                .overlay {
                    // Opaque, so the web view is never seen blank or half drawn.
                    if let cover = page.cover {
                        coverView(cover)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: VisualReviewRow.symbol)
                .foregroundStyle(.secondary)
            Text(verbatim: review.title ?? "Visual review")
                .font(.headline)
                .lineLimit(1)
            if let summary = review.summary {
                Text(verbatim: summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            EveryMinute { now in
                Text("updated \(review.updatedAt.ago(now: now))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            Button("Reload", systemImage: "arrow.clockwise") { page.load(review.reportURL) }
                .labelStyle(.iconOnly)
                .help("Load the report again")
            Button("Open in Browser", systemImage: "safari") { openInBrowser(review.reportURL) }
                .labelStyle(.iconOnly)
                .help("Open the report in the default browser")
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func coverView(_ cover: VisualReviewPage.Cover) -> some View {
        switch cover {
        case .loading:
            LoadingLabel(title: "Loading the visual review report…", detail: review.reportURL.host() ?? review.reportURL.absoluteString)
        case let .failed(failure):
            ContentUnavailableView {
                Label(failure.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message).textSelection(.enabled)
            } actions: {
                HStack {
                    Button("Try Again") { page.load(review.reportURL) }
                    Button("Open in Browser") { openInBrowser(review.reportURL) }
                    if let artifacts = review.artifactsURL {
                        Button("Open Artifacts Tab") { openInBrowser(artifacts) }
                    }
                }
                .fixedSize()
            }
        }
    }
}

private struct VisualReviewWebView: NSViewRepresentable {
    let page: VisualReviewPage
    let review: VisualReview
    let isShown: Bool
    /// Under a wait or failure, when it's hidden too, so it's never drawn over them.
    let isCovered: Bool

    func makeNSView(context: Context) -> WKWebView {
        page.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if isShown { page.show(review.reportURL) }
        let wasShown = !webView.isHidden
        webView.isHidden = !isShown || isCovered
        if isShown, !wasShown { webView.window?.makeFirstResponder(webView) }
    }
}

/// A PR tab's web view of CI's visual review report, made the first time the report is shown
/// and kept while the tab lives, so its place and chosen comparison survive switching away.
/// Unlike the conversation's, the report is someone else's interactive page and needs its own
/// scripts, so this view runs them. Its artifacts are fetched by Loupe with the user's CircleCI
/// token under the `loupe-artifact:` scheme, so the page never sees the token, and the view
/// stays on the report's artifact host, sending any other page to the browser. It keeps no
/// cookies or storage between runs.
@MainActor
@Observable
final class VisualReviewPage: NSObject {
    /// What covers the web view: a wait until the report has loaded, or why it couldn't.
    enum Cover: Equatable {
        case loading
        case failed(Failure)
    }

    struct Failure: Equatable {
        let title: String
        /// Markdown, for the command to type in code.
        let message: LocalizedStringKey
    }

    private(set) var cover: Cover? = .loading
    @ObservationIgnored let webView: WKWebView
    /// The report last asked for, in the browser's terms, which a newer report's URL is
    /// compared with.
    @ObservationIgnored private var reportURL: URL?

    private static let pages = NSMapTable<PullRequestTab, VisualReviewPage>.weakToStrongObjects()
    /// One for every page, so the token is read once a run.
    private static let artifacts = CircleCIArtifacts.live()

    /// The tab's page, made if it hasn't one yet.
    static func page(for tab: PullRequestTab) -> VisualReviewPage {
        if let page = pages.object(forKey: tab) { return page }
        let page = VisualReviewPage(artifacts: artifacts)
        pages.setObject(page, forKey: tab)
        return page
    }

    /// The tab's page if the report has ever been shown.
    static func existingPage(for tab: PullRequestTab) -> VisualReviewPage? {
        pages.object(forKey: tab)
    }

    private init(artifacts: CircleCIArtifacts) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let handler = ArtifactSchemeHandler(artifacts: artifacts)
        configuration.setURLSchemeHandler(handler, forURLScheme: CircleCIArtifacts.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        super.init()
        handler.page = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Loads the report at `url` unless it's the one already asked for, as when CI's comment
    /// names a newer run's report.
    func show(_ url: URL) {
        if url != reportURL { load(url) }
    }

    func load(_ url: URL) {
        reportURL = url
        guard let proxied = CircleCIArtifacts.proxyURL(for: url) else {
            return fail("Not a CircleCI artifact", "Loupe only opens reports kept as CircleCI artifacts; this one is at \(url.host() ?? url.absoluteString).")
        }
        cover = .loading
        webView.load(URLRequest(url: proxied))
    }

    /// Why the report itself, rather than something it loads, couldn't be fetched.
    fileprivate func artifactFailed(_ url: URL, _ outcome: CircleCIArtifacts.Outcome) {
        guard let reportURL, url == CircleCIArtifacts.proxyURL(for: reportURL) else { return }
        switch outcome {
        case .needsToken:
            fail("Loupe needs a CircleCI token", "The report is a private project's artifact. Make a personal API token in CircleCI's user settings and store it with `circleci setting set token`, or set `CIRCLE_TOKEN`, then try again.")
        case let .refused(status):
            fail("CircleCI refused the token", "CircleCI answered \(status) to the token from the circleci CLI's settings. Store a current one with `circleci setting set token`, then try again.")
        case let .loaded(_, _, status) where status >= 400:
            fail("Couldn't load the report", "CircleCI answered \(status) \(HTTPURLResponse.localizedString(forStatusCode: status)). The artifacts may have expired.")
        case let .failed(message):
            fail("Couldn't load the report", LocalizedStringKey(stringLiteral: message))
        case .loaded:
            break
        }
    }

    private func fail(_ title: String, _ message: LocalizedStringKey) {
        cover = .failed(Failure(title: title, message: message))
    }

    /// The report's artifact host, under either scheme.
    private func isReportHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == reportURL?.host()?.lowercased()
    }
}

extension VisualReviewPage: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased()
        if scheme == CircleCIArtifacts.scheme || scheme == "about" || scheme == "data" || scheme == "blob" { return .allow }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame != false
        // A link to another of the report's own files is fetched with the token too.
        if isMainFrame, isReportHost(url), let proxied = CircleCIArtifacts.proxyURL(for: url) {
            webView.load(URLRequest(url: proxied))
            return .cancel
        }
        // Another host's frame inside the report is left out; a page of its own goes to the browser.
        if isMainFrame { followLink(url, inBrowserTab: true) { _ in } }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if case .loading = cover { cover = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(with: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(with: error)
    }

    /// A link that asks for a new window opens here if it's the report's, else in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if url.scheme?.lowercased() == CircleCIArtifacts.scheme {
            webView.load(navigationAction.request)
        } else if isReportHost(url), let proxied = CircleCIArtifacts.proxyURL(for: url) {
            webView.load(URLRequest(url: proxied))
        } else {
            followLink(url, inBrowserTab: true) { _ in }
        }
        return nil
    }

    /// Cancelled loads, as when a policy stopped one or a newer replaced it, aren't failures;
    /// nor is one the artifact's own failure has already explained.
    private func failed(with error: any Error) {
        let error = error as NSError
        let isCancelled = (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == Self.frameLoadInterruptedByPolicyChange)
        guard !isCancelled else { return }
        if case .failed = cover { return }
        fail("Couldn't load the report", LocalizedStringKey(stringLiteral: error.localizedDescription))
    }

    /// WebKit's code for a load stopped by the navigation delegate's policy.
    private static let frameLoadInterruptedByPolicyChange = 102
}

/// Serves `loupe-artifact:` URLs to the report's web view, each fetched from CircleCI with the
/// user's token: the report, then each file it loads relative to it.
@MainActor
private final class ArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
    let artifacts: CircleCIArtifacts
    weak var page: VisualReviewPage?
    /// The fetches underway, by task, so a task WebKit has stopped is never answered.
    private var fetches: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(artifacts: CircleCIArtifacts) {
        self.artifacts = artifacts
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url else {
            return urlSchemeTask.didFailWithError(URLError(.badURL))
        }
        let artifacts = artifacts
        fetches[key] = Task { [weak self] in
            let outcome = await artifacts.fetch(url)
            guard let self, !Task.isCancelled, fetches.removeValue(forKey: key) != nil else { return }
            page?.artifactFailed(url, outcome)
            switch outcome {
            case let .loaded(data, mimeType, status):
                let headers = ["Content-Type": mimeType ?? "application/octet-stream", "Content-Length": "\(data.count)"]
                urlSchemeTask.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) ?? URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            case .needsToken, .refused:
                urlSchemeTask.didFailWithError(URLError(.userAuthenticationRequired))
            case let .failed(message):
                urlSchemeTask.didFailWithError(URLError(.cannotLoadFromNetwork, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        fetches.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}

/// An empty view behind the Visual review row, so a snapshot run can find where it is.
struct VisualReviewRowMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

extension VisualReview {
    /// "4 changed, 0 new, 0 removed", or just the count of stories when the counts couldn't be
    /// read; nil when neither could.
    var summary: String? {
        if let counts { return "\(counts.changed) changed, \(counts.new) new, \(counts.removed) removed" }
        return changeCount.map { "\($0) \($0 == 1 ? "story" : "stories") listed" }
    }
}

extension VisualReview.Status {
    var tint: Color {
        switch self {
        case .changed: .orange
        case .new: .diffSuccess
        case .removed: .diffDanger
        case .other: .secondary
        }
    }
}
