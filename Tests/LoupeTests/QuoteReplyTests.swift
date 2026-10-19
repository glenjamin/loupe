import Foundation
import LoupeCore
import Testing

struct QuoteReplyTests {
    @Test func aSelectionInRenderedHTMLComesBackAsMarkdown() {
        // As the conversation page hands it over: the selected nodes, inside the elements
        // they were selected within.
        let html = """
        <p dir="auto">Use <code class="notranslate">filter.Or</code> as in <a href="https://example.com/docs">the docs</a>, <strong>please</strong>, and <em>then</em> ask <a class="user-mention" href="/octocat">@octocat</a> about <a href="https://github.com/o/r/pull/1">#1</a></p>
        <div class="highlight highlight-source-go"><pre class="notranslate"><span class="pl-k">if</span> x &lt; 1 {
          return
        }
        </pre></div>
        <ul dir="auto">
        <li>one</li>
        <li>two
        <ol dir="auto"><li>nested</li></ol>
        </li>
        <li class="task-list-item"><input type="checkbox" checked="" disabled=""> done</li>
        </ul>
        <blockquote><p dir="auto">quoted</p></blockquote>
        """
        #expect(QuoteReply.markdown(fromHTML: html) == """
        Use `filter.Or` as in [the docs](https://example.com/docs), **please**, and _then_ ask @octocat about #1

        ```
        if x < 1 {
          return
        }
        ```

        - one
        - two
          1. nested
        - [x] done

        > quoted
        """)
    }

    @Test func partOfACodeBlockOrInlineCodeStaysCode() {
        #expect(QuoteReply.markdown(fromHTML: "<pre><code>return nil</code></pre>") == "```\nreturn nil\n```")
        #expect(QuoteReply.markdown(fromHTML: "<p><code>a `tick`</code></p>") == "`` a `tick` ``")
    }

    @Test func aQuoteMarksEveryLineAndLeavesABlankLineToWriteAfter() {
        #expect(QuoteReply.quoted("one\n\ntwo") == "> one\n>\n> two\n\n")
        #expect(QuoteReply.quoted("  \n") == "")
    }

    @Test func aSecondQuoteGoesAfterWhatsWrittenABlankLineApart() {
        #expect(QuoteReply.appending("> b\n\n", to: "") == "> b\n\n")
        #expect(QuoteReply.appending("> b\n\n", to: "> a\n\nI agree\n") == "> a\n\nI agree\n\n> b\n\n")
    }

    @Test func aSelectionInANativeBlockIsFoundByItsTextAndKeepsItsStyles() throws {
        let blocks = CommentBlock.blocks(fromHTML: """
        <p>Call <code>run()</code> with <a href="https://example.com">a link</a> first</p>
        <ul><li>one<ul><li>deeper item</li></ul></li></ul>
        <blockquote><p>said before</p></blockquote>
        <pre><code>let x = 1
        let y = 2</code></pre>
        """)
        let paragraph = "Call run() with a link first"
        #expect(QuoteReply.markdown(selecting: NSRange(location: 5, length: 17), of: paragraph, in: blocks) == "`run()` with [a link](https://example.com)")

        // From an item's start its marker and depth come too; from inside it, just the words.
        let item = "• deeper item"
        #expect(QuoteReply.markdown(selecting: NSRange(location: 0, length: 8), of: item, in: blocks) == "  - deeper")
        #expect(QuoteReply.markdown(selecting: NSRange(location: 2, length: 6), of: item, in: blocks) == "deeper")

        #expect(QuoteReply.markdown(selecting: NSRange(location: 0, length: 4), of: "said before", in: blocks) == "> said")
        #expect(QuoteReply.markdown(selecting: NSRange(location: 4, length: 15), of: "let x = 1\nlet y = 2", in: blocks) == "```\nx = 1\nlet y = 2\n```")

        #expect(QuoteReply.markdown(selecting: NSRange(location: 0, length: 3), of: "not in the comment", in: blocks) == nil)
        #expect(QuoteReply.markdown(selecting: NSRange(location: 3, length: 0), of: paragraph, in: blocks) == nil, "nothing selected")
    }
}
