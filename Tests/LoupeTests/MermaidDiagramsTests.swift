import AppKit
import Foundation
import LoupeCore
import Testing
import WebKit

/// GitHub's mermaid blocks, drawn in a page made from the app's own template, stylesheet and
/// Content-Security-Policy, as the conversation, previews and rendered files are.
@MainActor
struct MermaidDiagramsTests {
    @Test func aMermaidBlockInGitHubsHTMLIsDrawnInPlaceOfItsCode() async throws {
        let html = try descriptionHTML()
        #expect(MermaidDiagrams.appear(in: html))
        let view = try await loadedPage(html)

        #expect(await MermaidDiagrams.draw(in: view) == 1)

        let shown = try await state(of: view)
        #expect(shown["diagrams"] as? Int == 1)
        let labels = try #require(shown["labels"] as? String)
        #expect(["Recipe column", "Predicate", "Report query", "Drill-down table", "sqlb clause"].allSatisfy(labels.contains), "the diagram's own nodes and edges: \(labels)")
        #expect(shown["codeShown"] as? Bool == false, "the diagram takes the code block's place")
        #expect(shown["spinnerShown"] as? Bool == false)
        #expect((shown["width"] as? Double ?? 0) > 200, "drawn at a readable size")
    }

    @Test func aDiagramMermaidCantDrawStaysAsItsCodeWithNothingElseLeftBehind() async throws {
        let html = try descriptionHTML().replacingOccurrences(of: "flowchart LR", with: "flowchart LR\n  ((( not mermaid")
        let view = try await loadedPage(html)

        #expect(await MermaidDiagrams.draw(in: view) == 0)

        let shown = try await state(of: view)
        #expect(shown["diagrams"] as? Int == 0)
        #expect(shown["codeShown"] as? Bool == true, "the code shows as it would without Mermaid")
        #expect(shown["spinnerShown"] as? Bool == false, "nothing is waited for")
        #expect(shown["strays"] as? Int == 0, "no error drawing or half-made diagram in the page")
    }

    @Test func aDiagramTakesThePagesLightOrDark() async throws {
        let html = try descriptionHTML()
        var fills: [String] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = try await loadedPage(html, appearance: appearance)
            #expect(await MermaidDiagrams.draw(in: view) == 1)
            fills.append(try #require(try await state(of: view)["nodeFill"] as? String))
        }
        #expect(fills[0] != fills[1], "light and dark nodes differ: \(fills)")
        #expect(fills[0] == "rgb(236, 236, 255)", "Mermaid's light theme, as github.com's light theme draws it")
    }

    @Test func aDrawnDiagramTakesTheOtherThemeWhenTheAppearanceChanges() async throws {
        let view = try await loadedPage(descriptionHTML(), appearance: .aqua)
        #expect(await MermaidDiagrams.draw(in: view) == 1)
        let light = try #require(try await state(of: view)["nodeFill"] as? String)

        view.appearance = NSAppearance(named: .darkAqua)

        let dark = try await eventually { try await state(of: view)["nodeFill"] as? String } until: { $0 != light }
        #expect(dark != nil, "the diagram is drawn again in Mermaid's dark theme, not left light")
        let shown = try await state(of: view)
        #expect(shown["diagrams"] as? Int == 1, "the new drawing replaces the old")
        #expect(shown["codeShown"] as? Bool == false)
    }

    @Test func onlyAPageWithADiagramHasOneToDraw() async throws {
        let plain = #"<p dir="auto">No diagrams</p><div class="highlight highlight-source-yaml"><pre>mermaid: true</pre></div>"#
        #expect(!MermaidDiagrams.appear(in: plain))
        let view = try await loadedPage(plain)
        #expect(await MermaidDiagrams.draw(in: view) == 0)
    }
}

/// The description in `probe/conversation.json`, GitHub's own HTML, which ends in a mermaid block.
private func descriptionHTML() throws -> String {
    let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/conversation.json")))
    let node = try #require(((probe as? [String: Any])?["data"] as? [String: Any])?["node"] as? [String: Any])
    return try #require(node["bodyHTML"] as? String)
}

/// What the page shows of its mermaid blocks.
@MainActor
private func state(of view: WKWebView) async throws -> [String: Any] {
    let script = """
        const section = document.querySelector('section[data-type="mermaid"]');
        const svg = section?.querySelector('.mermaid-diagram svg');
        const shown = element => element != null && element.getClientRects().length > 0;
        return {
          diagrams: document.querySelectorAll('.mermaid-diagram svg').length,
          labels: svg?.textContent ?? '',
          codeShown: shown(section?.querySelector('pre')),
          spinnerShown: shown(section?.querySelector('.js-render-enrichment-loader')),
          width: svg?.getBoundingClientRect().width ?? 0,
          nodeFill: svg ? getComputedStyle(svg.querySelector('.node rect, .node polygon')).fill : '',
          strays: [...document.body.children].filter(child => child.tagName !== 'MAIN').length,
        };
        """
    let found = try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
    return try #require(found as? [String: Any])
}

/// A web view that has loaded `html` in the app's draft template, as a preview is.
@MainActor
func loadedPage(_ html: String, appearance: NSAppearance.Name = .aqua) async throws -> WKWebView {
    let resources = projectRoot.appending(path: "Sources/Loupe/Resources")
    let template = try String(contentsOf: resources.appending(path: "conversation.html"), encoding: .utf8)
    let stylesheet = try String(contentsOf: resources.appending(path: "conversation.css"), encoding: .utf8)
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.appearance = NSAppearance(named: appearance)
    let loading = PageLoading()
    view.navigationDelegate = loading
    await withCheckedContinuation { continuation in
        loading.finished = { continuation.resume() }
        view.loadHTMLString(MarkdownHTML.draftPage(html, template: template, stylesheet: stylesheet), baseURL: URL(string: "https://github.com/"))
    }
    return view
}

@MainActor
private final class PageLoading: NSObject, WKNavigationDelegate {
    var finished: () -> Void = {}

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished()
    }
}

/// `value` once `done` says it's what was waited for, polling for up to five seconds; nil if
/// it never was.
@MainActor
func eventually<Value>(_ value: @MainActor () async throws -> Value?, until done: (Value) -> Bool) async throws -> Value? {
    let deadline = Date.now.addingTimeInterval(5)
    while Date.now < deadline {
        if let found = try await value(), done(found) { return found }
        try await Task.sleep(for: .milliseconds(25))
    }
    return nil
}
