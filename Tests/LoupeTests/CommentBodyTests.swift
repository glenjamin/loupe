import Foundation
import LoupeCore
import Testing

struct CommentBodyTests {
    @Test func githubsRenderingBecomesParagraphsCodeQuotesListsAndLinks() throws {
        let html = """
        <p dir="auto">Use <code class="notranslate">filter.Or</code> &amp; see <a href="https://github.com/o/r/pull/1">#1</a>, <strong>please</strong><br>
        and <em>then</em> <a href="/o/r/blob/main/x.go">x.go</a></p>
        <pre class="notranslate"><code class="notranslate">if x &lt; 1 {
          return
        }
        </code></pre>
        <blockquote>
        <p dir="auto">quoted text</p>
        </blockquote>
        <ul dir="auto">
        <li>one</li>
        <li>two
        <ol dir="auto"><li>nested</li></ol>
        </li>
        <li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" checked="" disabled=""> done</li>
        </ul>
        <!-- a comment -->
        <p dir="auto"><a target="_blank" rel="noopener noreferrer" href="https://github.com/user-attachments/assets/abc"><img src="https://github.com/user-attachments/assets/abc" alt="screenshot" style="max-width: 100%;"></a> <svg><path d="M0"></path></svg></p>
        <hr>
        """
        let blocks = CommentBlock.blocks(fromHTML: html)
        #expect(blocks.map(\.summary) == [
            "text 0: Use filter.Or & see #1, please\nand then x.go",
            "code: if x < 1 {\n  return\n}",
            "quote: [text 0: quoted text]",
            "text 0: • one",
            "text 0: • two",
            "text 1: 1. nested",
            "text 0: • ☑ done",
            "text 0: [screenshot]",
            "rule",
        ])

        guard case let .text(first, _) = blocks[0] else { return }
        #expect(first.runs(of: "filter.Or").allSatisfy { $0.inlinePresentationIntent == .code })
        #expect(first.runs(of: "#1").allSatisfy { $0.link == URL(string: "https://github.com/o/r/pull/1") })
        #expect(first.runs(of: "please").allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(first.runs(of: "then").allSatisfy { $0.inlinePresentationIntent == .emphasized })
        #expect(first.runs(of: "x.go").allSatisfy { $0.link == URL(string: "https://github.com/o/r/blob/main/x.go") }, "made absolute")
        guard case let .text(image, _) = blocks[7] else { return }
        #expect(image.runs(of: "[screenshot]").allSatisfy { $0.link == URL(string: "https://github.com/user-attachments/assets/abc") }, "a link, not fetched")
    }


    @Test func emojiReadAsTheirCharacterOrForGitHubsOwnTheirName() throws {
        let html = """
        <p dir="auto">Ship it <g-emoji class="g-emoji" alias="tada" fallback-src="https://github.githubassets.com/images/icons/emoji/unicode/1f389.png">🎉</g-emoji> \
        <g-emoji class="g-emoji" alias="+1">👍</g-emoji> <img class="emoji" title=":shipit:" alt=":shipit:" src="https://github.githubassets.com/images/icons/emoji/shipit.png" height="20" width="20" align="absmiddle"></p>
        """
        let blocks = CommentBlock.blocks(fromHTML: html)
        #expect(blocks.map(\.summary) == ["text 0: Ship it 🎉 👍 :shipit:"])
        guard case let .text(text, _) = blocks.first else { return }
        #expect(text.runs(of: ":shipit:").allSatisfy { $0.link == nil }, "an emoji, not a link to its image")
    }

    @Test func readsTheProbesComments() throws {
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/conversation.json")))
        let node = try #require(((probe as? [String: Any])?["data"] as? [String: Any])?["node"] as? [String: Any])
        let threads = try #require((node["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]])
        let comments = threads.flatMap { (($0["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] }
        for comment in comments {
            let html = try #require(comment["bodyHTML"] as? String)
            let blocks = CommentBlock.blocks(fromHTML: html)
            #expect(!blocks.isEmpty)
            #expect(!blocks.map(\.summary).joined().contains("<"), "no markup left in \(html)")
        }
        let reply = try #require(comments.first { ($0["bodyHTML"] as? String)?.contains("what's your thinking") == true })
        let blocks = CommentBlock.blocks(fromHTML: try #require(reply["bodyHTML"] as? String))
        #expect(blocks.first?.summary == "text 0: what's your thinking with this?")
    }
}

private extension CommentBlock {
    /// The block's kind and plain text, nested blocks in brackets.
    var summary: String {
        switch self {
        case let .text(text, indent): "text \(indent): \(String(text.characters))"
        case let .code(code): "code: \(code)"
        case let .quote(blocks): "quote: [\(blocks.map(\.summary).joined(separator: ", "))]"
        case .rule: "rule"
        case let .suggestion(removed, added):
            "suggestion: " + (removed.map { "-\($0.number.map(String.init) ?? "") \($0.text)" } + added.map { "+\($0.number.map(String.init) ?? "") \($0.text)" }).joined(separator: " | ")
        }
    }
}

private extension AttributedString {
    /// The runs covering each occurrence of `text`.
    func runs(of text: String) -> [AttributedString.Runs.Run] {
        guard let range = range(of: text) else { return [] }
        return Array(self[range].runs)
    }
}
