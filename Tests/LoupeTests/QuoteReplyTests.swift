import Foundation
import LoupeCore
import Testing

/// Selections in a comment as the diff's cards show it, quoted as github.com's quote-selection
/// does from the same selection in GitHub's rendering.
@MainActor
struct QuoteReplyTests {
    @Test func inlineMarkupInsideTheSelectionIsWrittenAsMarkdownWithMentionsReferencesAndBareURLsAsTheyAre() async {
        let paragraph = "Use filter.Or as in the docs, please, then not this ask @octocat about #1 and https://example.com/raw\nSecond line after a soft break."
        // DEL is written with single tildes, and a line break stays one.
        #expect(await quote(paragraph, in: paragraph) == "Use `filter.Or` as in [the docs](https://example.com/docs), **please**, _then_ ~not this~ ask @octocat about #1 and https://example.com/raw\nSecond line after a soft break.")
        #expect(await quote("filter.Or as in the docs", in: paragraph) == "`filter.Or` as in [the docs](https://example.com/docs)")
    }

    @Test func partOfALinkOrOfInlineCodeIsPlainTextAsOnlyWholeElementsAreConverted() async {
        let paragraph = "Use filter.Or as in the docs, please, then not this ask @octocat about #1 and https://example.com/raw\nSecond line after a soft break."
        #expect(await quote("docs", in: paragraph) == "docs")
        #expect(await quote("filter", in: paragraph) == "filter")
        #expect(await quote("please", in: paragraph) == "please")
    }

    @Test func aHeadingsOwnTextIsQuotedWithoutItsMarkersAsTheHeadingElementIsntSelected() async {
        #expect(await quote("Plan", in: "Plan") == "Plan")
    }

    @Test func aHighlightedCodeBlockIsFencedWithItsLanguageWhateverPartIsSelected() async {
        let code = "if x < 1 {\n\treturn\n}"
        #expect(await quote(code, in: code) == "```go\nif x < 1 {\n\treturn\n}\n```")
        #expect(await quote("x < 1", in: code) == "```go\nx < 1\n```")
    }

    @Test func partOfAPlainCodeBlockIsItsTextUnfencedAsItsCodeElementIsntSelected() async {
        #expect(await quote("plain code", in: "plain code") == "plain code")
    }

    @Test func aSelectionInAListItemKeepsItsMarkerFromAnywhereInItButNotItsDepth() async {
        #expect(await quote("1. first", in: "1. first") == "1. first")
        // Past an ordered list's first item the number is escaped, so it isn't a list renumbered.
        #expect(await quote("2. second", in: "2. second") == "2\\. second")
        #expect(await quote("econd", in: "2. second") == "2\\. econd")
        #expect(await quote("• nested two", in: "• nested two") == "* nested two")
        #expect(await quote("nested", in: "• nested one") == "* nested")
    }

    @Test func aTaskItemFromItsBoxKeepsTheBoxButNotTheBullet() async {
        #expect(await quote("• ☑ done", in: "• ☑ done") == "[x] done")
        #expect(await quote("☐ todo", in: "• ☐ todo") == "[ ] todo")
        #expect(await quote("todo", in: "• ☐ todo") == "* todo")
    }

    @Test func textInsideAQuoteIsntQuotedTwiceAsTheBlockquoteIsntSelected() async {
        #expect(await quote("quoted\nmore", in: "quoted\nmore") == "quoted\nmore")
    }

    @Test func aTableRowsCellsAreSeparatedByTabs() async {
        #expect(await quote("1   |  2", in: "1   |  2") == "1\t2")
    }

    @Test func anImageIsMarkdownForItsSourceAndAnEmojiItsCharacter() async {
        let line = "[screenshot] 👍"
        #expect(await quote(line, in: line) == "![screenshot](https://camo.githubusercontent.com/33ced0/shot) 👍")
        #expect(await quote("👍", in: line) == "👍")
    }

    @Test func anImageAloneHasNoTextSoTheWholeCommentIsQuoted() async {
        let html = #"<p>Before</p>\#n<p><a href="https://example.com/a.png"><img src="https://example.com/a.png" alt="screenshot"></a> <g-emoji>👍</g-emoji></p>"#
        #expect(await quote("[screenshot]", in: "[screenshot] 👍", from: html) == "Before\n\n![screenshot](https://example.com/a.png) 👍")
    }

    @Test func aSelectionOfOnlyWhitespaceQuotesTheWholeComment() async {
        #expect(await quoteAll(selectingASpaceIn: "Use it", from: "<h2 dir=\"auto\">Plan</h2>\n<p dir=\"auto\">Use it</p>") == "## Plan\nUse it")
    }

    @Test func aWholeCommentIsQuotedAsQuoteSelectionsOwnFixtureIs() async {
        // quote-selection's "preserves formatting" test.
        let html = """
            <p>This is <strong>beautifully</strong> formatted <em>text</em> that even has some <code>inline code</code>.</p>
            <p>This is a simple p line</p>
            <p>some escaped html tags to ignore &lt;pre&gt; &lt;strong&gt; &lt;weak&gt; &lt;em&gt; &lt;/pre&gt; &lt;/strong&gt; &lt;/weak&gt; &lt;/em&gt;</p>
            <pre><code>foo(true)</code></pre>
            <p><a href="http://example.com">Links</a> and <img alt=":emoji:" class="emoji" src="image.png"> are preserved.</p>
            <blockquote><p>Music changes, and I'm gonna change right along with it.<br>--Aretha Franklin</p></blockquote>
            """
        let markdown = await quoteAll(selectingASpaceIn: "This is a simple p line", from: html)
        // The fixture passes `.emoji` images through; github.com writes their alt text.
        #expect(markdown.map(QuoteReply.quoted)?.replacing(/[ ]+\n/, with: "\n") == """
            > This is **beautifully** formatted _text_ that even has some `inline code`.
            >
            > This is a simple p line
            >
            > some escaped html tags to ignore \\<pre\\> \\<strong\\> \\<weak\\> \\<em\\> \\</pre\\> \\</strong\\> \\</weak\\> \\</em\\>
            >
            > ```
            > foo(true)
            > ```
            >
            > [Links](http://example.com) and :emoji: are preserved.
            >
            > > Music changes, and I'm gonna change right along with it.--Aretha Franklin


            """)
    }

    @Test func nestedListsAreQuotedAsQuoteSelectionsOwnFixtureIs() async {
        // quote-selection's "preserves list order" test.
        let html = """
            <ol dir="auto">
            <li>Top level list one
            <ul dir="auto">
            <li>
            <ol dir="auto">
            <li>sublist one</li>
            </ol>
            </li>
            <li>
            <ol start="2" dir="auto">
            <li>sublist  two</li>
            </ol>
            </li>
            <li>
            <ol start="5" dir="auto">
            <li>sublist  three</li>
            </ol>
            </li>
            </ul>
            </li>
            <li>Top level list two</li>
            <li>Top level list three
            <ol dir="auto">
            <li>sublist one</li>
            <li>sublist two</li>
            <li>sublist three</li>
            </ol>
            </li>
            </ol>
            """
        let markdown = await quoteAll(selectingASpaceIn: "2. Top level list two", from: html)
        #expect(markdown.map(QuoteReply.quoted)?.replacing(/[ ]+\n/, with: "\n") == """
            > 1. Top level list one
            >
            >    * 1. sublist one
            >    * 2. sublist  two
            >    * 5. sublist  three
            > 2. Top level list two
            > 3. Top level list three
            >
            >    1. sublist one
            >    2. sublist two
            >    3. sublist three


            """)
    }

    @Test func nothingIsQuotedForNoSelectionOrABlockNotInTheComment() async {
        #expect(await QuoteConverter.shared.markdown(selecting: NSRange(location: 2, length: 0), of: "Plan", inComment: Self.comment) == nil)
        #expect(await QuoteConverter.shared.markdown(selecting: NSRange(location: 0, length: 3), of: "not in the comment", inComment: Self.comment) == nil)
    }

    @Test func aQuoteMarksEveryLineBlankOnesTooAndLeavesABlankLineToWriteAfter() {
        #expect(QuoteReply.quoted("one\n\ntwo") == "> one\n> \n> two\n\n")
    }

    @Test func aQuoteGoesAfterWhatsWrittenABlankLineApartAsItIs() {
        #expect(QuoteReply.appending("> b\n\n", to: "") == "> b\n\n")
        #expect(QuoteReply.appending("> b\n\n", to: "I agree") == "I agree\n\n> b\n\n")
        #expect(QuoteReply.appending("> b\n\n", to: "> a\n\n") == "> a\n\n\n\n> b\n\n")
    }

    /// The markdown github.com writes for `selected`, the first time it's in the block shown as
    /// `block`, in the comment `html`.
    private func quote(_ selected: String, in block: String, from html: String = Self.comment) async -> String? {
        let range = (block as NSString).range(of: selected)
        #expect(range.location != NSNotFound, "\(selected) is in \(block)")
        return await QuoteConverter.shared.markdown(selecting: range, of: block, inComment: html)
    }

    /// The markdown github.com writes for a selection of only the last space in `block`, which
    /// quotes the whole comment.
    private func quoteAll(selectingASpaceIn block: String, from html: String) async -> String? {
        let range = (block as NSString).range(of: " ", options: .backwards)
        return await QuoteConverter.shared.markdown(selecting: range, of: block, inComment: html)
    }

    /// GitHub's rendering of a comment using most of its markdown, as its API gives it.
    private static let comment = """
        <h2 dir="auto">Plan</h2>
        <p dir="auto">Use <code class="notranslate">filter.Or</code> as in <a href="https://example.com/docs" rel="nofollow">the docs</a>, <strong>please</strong>, <em>then</em> <del>not this</del> ask <a class="user-mention notranslate" data-hovercard-type="user" data-hovercard-url="/users/octocat/hovercard" data-octo-click="hovercard-link-click" data-octo-dimensions="link_type:self" href="https://github.com/octocat">@octocat</a> about <a class="issue-link js-issue-link" data-error-text="Failed to load title" data-id="132" data-permission-text="Title is private" data-url="https://github.com/rails/rails/issues/1" data-hovercard-type="issue" data-hovercard-url="/rails/rails/issues/1/hovercard" href="https://github.com/rails/rails/issues/1">#1</a> and <a href="https://example.com/raw" rel="nofollow">https://example.com/raw</a><br>
        Second line after a soft break.</p>
        <div class="highlight highlight-source-go notranslate position-relative overflow-auto" dir="auto"><pre class="notranslate"><span class="pl-k">if</span> <span class="pl-s1">x</span> <span class="pl-c1">&lt;</span> <span class="pl-c1">1</span> {
        \t<span class="pl-k">return</span>
        }</pre></div>
        <div class="snippet-clipboard-content notranslate position-relative overflow-auto"><pre class="notranslate"><code class="notranslate">plain code
        </code></pre></div>
        <ol dir="auto">
        <li>first</li>
        <li>second
        <ul dir="auto">
        <li>nested one</li>
        <li>nested two</li>
        </ul>
        </li>
        <li>third</li>
        </ol>
        <ul class="contains-task-list">
        <li class="task-list-item"><input type="checkbox" id="" disabled="" class="task-list-item-checkbox" aria-label="Completed task" checked=""> done</li>
        <li class="task-list-item"><input type="checkbox" id="" disabled="" class="task-list-item-checkbox" aria-label="Incomplete task"> todo</li>
        </ul>
        <blockquote>
        <p dir="auto">quoted<br>
        more</p>
        </blockquote>
        <markdown-accessiblity-table><table role="table">
        <thead>
        <tr>
        <th>a</th>
        <th>b</th>
        </tr>
        </thead>
        <tbody>
        <tr>
        <td>1</td>
        <td>2</td>
        </tr>
        </tbody>
        </table></markdown-accessiblity-table>
        <p dir="auto"><a target="_blank" rel="noopener noreferrer nofollow" href="https://camo.githubusercontent.com/33ced0/shot"><img src="https://camo.githubusercontent.com/33ced0/shot" alt="screenshot" data-canonical-src="https://example.com/shot.png" style="max-width: 100%;"></a> <g-emoji class="g-emoji" alias="+1">👍</g-emoji></p>
        """
}
