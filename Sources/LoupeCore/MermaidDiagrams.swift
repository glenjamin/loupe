import Foundation
import WebKit

/// GitHub's mermaid diagrams, drawn in a page of its HTML as github.com draws them, by the
/// vendored Mermaid run in a script world of the app's own, as the page runs no script itself.
/// GitHub sends a diagram as its source, marked for github.com to draw from its own host; here
/// it's drawn offline, only on a page that has one, so other pages never load Mermaid.
@MainActor
public enum MermaidDiagrams {
    /// Whether GitHub's HTML has a diagram to draw.
    public static func appear(in html: String) -> Bool {
        html.contains(#"data-type="mermaid""#)
    }

    /// Draws the loaded page's diagrams in place; returns how many were drawn. One Mermaid can't
    /// draw stays as its code, as does every one if the app is missing Mermaid.
    @discardableResult
    public static func draw(in webView: WKWebView) async -> Int {
        guard let script else { return 0 }
        guard (try? await webView.evaluateJavaScript(script, in: nil, contentWorld: world)) != nil else { return 0 }
        let drawn = try? await webView.callAsyncJavaScript("return await drawDiagrams()", arguments: [:], in: nil, contentWorld: world)
        return drawn as? Int ?? 0
    }

    /// Kept apart from the app's other page scripts, as Mermaid fills its world's globals.
    private static let world = WKContentWorld.world(name: "LoupeMermaid")

    /// Mermaid, then the app's code that draws GitHub's diagrams with it, ending in a value
    /// WebKit can hand back, so evaluating it says whether it ran.
    private static let script: String? = {
        let sources = ["mermaid/mermaid.min.js", "mermaid-diagrams.js"].map { path in
            bundledResource(path, in: "Loupe_LoupeCore").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let mermaid = sources[0], let diagrams = sources[1] else { return nil }
        return mermaid + "\n" + diagrams + "\ntrue"
    }()
}
