import AppKit
import LoupeCore
import Testing

struct TerminalTextTests {
    @Test func coloursAndStylesFollowTheEscapesAndAreDroppedFromTheText() throws {
        let text = TerminalText.attributed("plain \u{1B}[31mred\u{1B}[39m \u{1B}[1;38;5;34mbold green\u{1B}[0m \u{1B}[38;2;10;20;30mrgb\u{1B}[m\n")

        #expect(text.string == "plain red bold green rgb\n")
        #expect(color(in: text, at: "plain") == .textColor)
        #expect(color(in: text, at: "red") != .textColor)
        #expect(color(in: text, at: "red") == color(in: TerminalText.attributed("\u{1B}[31mx"), at: "x"), "one red throughout")
        let bold = try #require(text.attribute(.font, at: offset(of: "bold", in: text), effectiveRange: nil) as? NSFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let rgb = try #require(color(in: text, at: "rgb")?.usingColorSpace(.sRGB))
        #expect(Int(rgb.redComponent * 255) == 10 && Int(rgb.greenComponent * 255) == 20 && Int(rgb.blueComponent * 255) == 30)
    }

    @Test func aLoneCarriageReturnRewritesTheLineAsATerminalDoes() {
        let text = TerminalText.attributed("[1/3] Running…\r[2/3] Running…\r[3/3] Done\r\nnext\r\n\u{1B}]0;title\u{07}after\u{1B}[2K")

        #expect(text.string == "[3/3] Done\nnext\nafter")
    }
}

private func offset(of word: String, in text: NSAttributedString) -> Int {
    (text.string as NSString).range(of: word).location
}

private func color(in text: NSAttributedString, at word: String) -> NSColor? {
    text.attribute(.foregroundColor, at: offset(of: word, in: text), effectiveRange: nil) as? NSColor
}
