import AppKit
import Foundation
import Testing
import WebKit

/// The pages of GitHub's HTML, made from the app's own template and stylesheet, follow the
/// system appearance in Primer's light and dark themes, as github.com does.
@MainActor
struct PageAppearanceTests {
    @Test func aPageIsInGitHubsLightOrDarkThemeAsTheAppearanceIs() async throws {
        let light = try await colours(of: loadedPage(Self.sample, appearance: .aqua))
        #expect(light == Colours(background: "rgb(255, 255, 255)", text: "rgb(31, 35, 40)", link: "rgb(9, 105, 218)", keyword: "rgb(207, 34, 46)"))

        let dark = try await colours(of: loadedPage(Self.sample, appearance: .darkAqua))
        #expect(dark == Colours(background: "rgb(13, 17, 23)", text: "rgb(240, 246, 252)", link: "rgb(68, 147, 248)", keyword: "rgb(255, 123, 114)"))
    }

    @Test func anOpenPageRestylesWhenTheAppearanceChanges() async throws {
        let view = try await loadedPage(Self.sample, appearance: .aqua)

        view.appearance = NSAppearance(named: .darkAqua)
        let dark = try await eventually { try await colours(of: view) } until: { $0.background == "rgb(13, 17, 23)" }
        #expect(dark?.keyword == "rgb(255, 123, 114)", "without loading it again")

        view.appearance = NSAppearance(named: .aqua)
        let light = try await eventually { try await colours(of: view) } until: { $0.background == "rgb(255, 255, 255)" }
        #expect(light?.text == "rgb(31, 35, 40)")
    }

    @Test func anImageMarkedForOneThemeShowsOnlyInThatTheme() async throws {
        let html = #"<p dir="auto"><img src="https://github.com/user-attachments/assets/1#gh-light-mode-only" alt="light"><img src="https://camo.githubusercontent.com/2" data-canonical-src="https://example.com/logo.png#gh-dark-mode-only" alt="dark"><img src="https://github.com/user-attachments/assets/3" alt="either"></p>"#
        let script = "return [...document.querySelectorAll('img')].filter(image => getComputedStyle(image).display !== 'none').map(image => image.alt)"
        for (appearance, shown) in [(NSAppearance.Name.aqua, ["light", "either"]), (.darkAqua, ["dark", "either"])] {
            let view = try await loadedPage(html, appearance: appearance)
            let found = try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String]
            #expect(found == shown, "in \(appearance.rawValue)")
        }
    }

    /// A link and a highlighted code block, as GitHub renders them.
    static let sample = #"<p dir="auto">See <a href="https://example.com/">this</a></p><div class="highlight highlight-source-go"><pre><span class="pl-k">func</span> main() {}</pre></div>"#
}

private struct Colours: Equatable {
    let background, text, link, keyword: String
}

/// The page's computed colours.
@MainActor
private func colours(of view: WKWebView) async throws -> Colours {
    let script = """
        const colour = (selector, property) => getComputedStyle(document.querySelector(selector))[property];
        return [colour('body', 'backgroundColor'), colour('p', 'color'), colour('a', 'color'), colour('.pl-k', 'color')];
        """
    let found = try #require(try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String])
    return Colours(background: found[0], text: found[1], link: found[2], keyword: found[3])
}
