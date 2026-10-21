import AppKit
import SwiftUI

/// A paragraph of a comment with its inline code set as github.com sets it: a smaller monospaced
/// font on a rounded grey pill, padded from the text around it.
struct InlineCodeText: View {
    let text: AttributedString

    var body: some View {
        if #available(macOS 15, *) {
            // Selectable text is drawn by AppKit, which skips a text renderer, so the pills are
            // drawn by the same text laid out again behind it, unselectable and showing nothing else.
            Text(segments.reduce(into: AttributedString()) { $0 += $1.text })
                .background(alignment: .topLeading) {
                    segments.reduce(Text(verbatim: "")) { result, segment in
                        result + (segment.isCode ? Text(segment.text).customAttribute(InlineCodeRun()) : Text(segment.text))
                    }
                    .textRenderer(InlineCodePills())
                    .textSelection(.disabled)
                    .accessibilityHidden(true)
                }
        } else {
            // Without a text renderer the pill can only be a flat background.
            Text(segments.reduce(into: AttributedString()) { result, segment in
                var piece = segment.text
                if segment.isCode { piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = InlineCode.background }
                result += piece
            })
        }
    }

    /// The text split where inline code starts and ends, the code in its font and the padding
    /// either side of it made room for with kerning, so the characters stay those of the block,
    /// which quoting a selection relies on.
    private var segments: [(text: AttributedString, isCode: Bool)] {
        var segments: [(text: AttributedString, isCode: Bool)] = []
        for run in text.runs {
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            var piece = AttributedString(text[run.range])
            if isCode { piece[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = InlineCode.font }
            if let last = segments.indices.last, segments[last].isCode == isCode {
                segments[last].text += piece
            } else {
                segments.append((piece, isCode))
            }
        }
        for index in segments.indices where segments[index].isCode {
            padEnd(of: &segments[index].text)
            if index > 0 { padEnd(of: &segments[index - 1].text) }
        }
        return segments
    }
}

/// How inline code looks: Primer's `--bgColor-neutral-muted` and `code` styles.
enum InlineCode {
    static let font = Font.system(size: size, design: .monospaced)
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x65 / 255, green: 0x6C / 255, blue: 0x76 / 255, alpha: 0.2)
            : NSColor(srgbRed: 0x81 / 255, green: 0x8B / 255, blue: 0x98 / 255, alpha: 0.12)
    })
    static let size = NSFont.systemFontSize * 0.85
    static let horizontalPadding = size * 0.4
    static let verticalPadding = size * 0.15
    static let cornerRadius: CGFloat = 6
}

/// Marks a run of inline code for `InlineCodePills` to draw behind.
@available(macOS 15, *)
private struct InlineCodeRun: TextAttribute {}

/// Draws a pill for each line's part of each span of inline code, and nothing else.
@available(macOS 15, *)
private struct InlineCodePills: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            // The kerning that pads the code splits its runs, so touching runs make one pill.
            var spans: [CGRect] = []
            var previousWasCode = false
            for run in line {
                let isCode = run[InlineCodeRun.self] != nil
                if isCode {
                    let bounds = run.typographicBounds.rect
                    if previousWasCode, let last = spans.popLast() {
                        spans.append(last.union(bounds))
                    } else {
                        spans.append(bounds)
                    }
                }
                previousWasCode = isCode
            }
            for span in spans {
                // The span's width takes in the kerning after its last character; the room before
                // its first is in the run ahead of it.
                let pill = CGRect(x: span.minX - InlineCode.horizontalPadding, y: span.minY - InlineCode.verticalPadding,
                                  width: span.width + InlineCode.horizontalPadding, height: span.height + 2 * InlineCode.verticalPadding)
                context.fill(Path(roundedRect: pill, cornerRadius: InlineCode.cornerRadius), with: .color(InlineCode.background))
            }
        }
    }
}

/// Adds the code's padding after the last character of `text`.
private func padEnd(of text: inout AttributedString) {
    guard !text.characters.isEmpty else { return }
    let last = text.characters.index(before: text.endIndex)
    text[last...][AttributeScopes.SwiftUIAttributes.KerningAttribute.self] = InlineCode.horizontalPadding
}
