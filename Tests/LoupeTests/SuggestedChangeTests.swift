import Foundation
import LoupeCore
import Testing

/// "Insert a suggestion" in a comment box, as github.com's "Add a suggestion" does, and
/// suggestions in comments as GitHub renders them.
struct SuggestedChangeTests {
    @Test func anEmptyDraftTakesTheBlockWithTheLinesIndentedAsTheyAreAndTheCursorAfterThem() {
        let lines = ["\tif err != nil {", "\t\treturn  err"]
        let (text, cursor) = insert(lines, into: "", at: 0)
        #expect(text == "```suggestion\n\tif err != nil {\n\t\treturn  err\n```")
        #expect(cursor == "```suggestion\n\tif err != nil {\n\t\treturn  err".utf16.count, "inside the block, at the end of its lines")
    }

    @Test func textAlreadyWrittenIsKeptWithTheBlockOnLinesOfItsOwn() {
        #expect(insert(["  x := 1"], into: "Nit:", at: 4).text == "Nit:\n```suggestion\n  x := 1\n```")
        #expect(insert(["  x := 1"], into: "Nit:\n", at: 5).text == "Nit:\n```suggestion\n  x := 1\n```", "no blank line where there's a line break already")

        let (text, cursor) = insert(["x"], into: "Before after", at: 7)
        #expect(text == "Before \n```suggestion\nx\n```\nafter")
        #expect((text as NSString).substring(to: cursor).hasSuffix("```suggestion\nx"))
        #expect(insert(["x"], into: "Top\n\nBottom", at: 4).text == "Top\n```suggestion\nx\n```\nBottom", "on the blank line between paragraphs")
    }

    @Test func aSelectionIsReplaced() {
        let edit = SuggestedChange.insertion(of: ["x"], into: "Change this please", replacing: NSRange(location: 7, length: 4))
        #expect(edit.applied(to: "Change this please") == "Change \n```suggestion\nx\n```\n please")
    }

    @Test func aSuggestionInACommentShowsTheLinesItReplacesThenThoseItPutsInTheirPlace() {
        let html = """
        <p dir="auto">Reword, and keep the tab:</p>
          <div class="my-2 border rounded-2 js-suggested-changes-blob diff-view js-check-hidden-unicode" id="">
            <div class="f6 p-2 lh-condensed border-bottom d-flex">
              <div class="flex-auto flex-items-center color-fg-muted">
                Suggested change
              </div>
            </div>
            <div itemprop="text" class="blob-wrapper data file rounded-0" style="margin: 0; border: none; overflow-y: visible; overflow-x: auto;">
              <table class="d-table tab-size mb-0 width-full" data-paste-markdown-skip="">
                  <tbody><tr class="border-0">
                    <td class="blob-num blob-num-deletion text-right border-0 px-2 py-1 lh-default" data-line-number="41"></td>
                    <td class="border-0 px-2 py-1 blob-code-inner blob-code-deletion js-blob-code-deletion blob-code-marker-deletion">\t<span class="pl-c">// Rows <span class="x x-first x-last">without</span> a key are skipped</span></td>
                  </tr>
                  <tr class="border-0">
                    <td class="blob-num blob-num-deletion text-right border-0 px-2 py-1 lh-default" data-line-number="42"></td>
                    <td class="border-0 px-2 py-1 blob-code-inner blob-code-deletion js-blob-code-deletion blob-code-marker-deletion">\t<span class="pl-k">if</span> a &lt; b {</td>
                  </tr>
                  <tr class="border-0">
                    <td class="blob-num blob-num-addition text-right border-0 px-2 py-1 lh-default" data-line-number="41"></td>
                    <td class="border-0 px-2 py-1 blob-code-inner blob-code-addition js-blob-code-addition blob-code-marker-addition">\t<span class="pl-c">// Rows <span class="x x-first x-last">with no</span> key are skipped</span></td>
                  </tr>
              </tbody></table>
            </div>
            <div class="js-apply-changes"></div>
          </div>
        <p dir="auto">Thanks!</p>
        """
        let blocks = CommentBlock.blocks(fromHTML: html)
        #expect(blocks.count == 3)
        #expect(blocks[1] == .suggestion(
            removed: [SuggestedLine(number: 41, text: "\t// Rows without a key are skipped"), SuggestedLine(number: 42, text: "\tif a < b {")],
            added: [SuggestedLine(number: 41, text: "\t// Rows with no key are skipped")]
        ))
        guard case let .text(after, _) = blocks[2] else { return }
        #expect(String(after.characters) == "Thanks!", "the comment goes on after it")
    }
}

/// The text and cursor after inserting a suggestion of `lines` at `cursor` in `text`.
private func insert(_ lines: [String], into text: String, at cursor: Int) -> (text: String, cursor: Int) {
    let edit = SuggestedChange.insertion(of: lines, into: text, replacing: NSRange(location: cursor, length: 0))
    #expect(edit.selection.length == 0)
    return (edit.applied(to: text), edit.selection.location)
}
