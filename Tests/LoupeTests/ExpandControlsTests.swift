import AppKit
import LoupeCore
import Testing

@MainActor
struct ExpandControlsTests {
    @Test func hunkHeadersOfferToRevealTheUnchangedLinesAroundThem() throws {
        let s3 = try fixtureFile("s3.go")
        let file = newFile(for: s3, trailing: 7)
        let rendered = RenderedDiff(file: s3, expandable: ExpandableContext(newLineCount: file.count))

        // One line above the first hunk; two between the first and second, so one arrow closes
        // the gap; 44 before the third, so it can grow from either side; one before the last.
        #expect(controls(onRow: rendered.hunkRows[0], of: rendered) == ["↑": ContextExpansion(hunk: 0, direction: .above)])
        #expect(controls(onRow: rendered.hunkRows[1], of: rendered) == ["↕": ContextExpansion(hunk: 1, direction: .above, lines: nil)])
        #expect(controls(onRow: rendered.hunkRows[2], of: rendered) == [
            "↓": ContextExpansion(hunk: 1, direction: .below),
            "↑": ContextExpansion(hunk: 2, direction: .above),
        ])
        #expect(controls(onRow: rendered.hunkRows[3], of: rendered) == ["↕": ContextExpansion(hunk: 3, direction: .above, lines: nil)])
        let trailing = try #require(rendered.trailingRow)
        #expect(trailing == rendered.rowStarts.count - 1)
        #expect(controls(onRow: trailing, of: rendered) == ["↓": ContextExpansion(hunk: 3, direction: .below)])

        // The end is offered once the file's length is known, and nothing without its text.
        #expect(RenderedDiff(file: s3, expandable: ExpandableContext()).trailingRow == nil)
        let plain = RenderedDiff(file: s3)
        #expect(plain.trailingRow == nil)
        #expect(plain.rowStarts.indices.allSatisfy { controls(onRow: $0, of: plain).isEmpty })
        #expect(plain.text.length < rendered.text.length)
    }

    @Test func clickingAnArrowAsksForItAndTheHunkStaysPutAsTheLinesArrive() throws {
        let s3 = try fixtureFile("s3.go")
        let file = newFile(for: s3)
        let expandable = ExpandableContext(newLineCount: file.count)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        scroll.documentView = view
        view.show(RenderedDiff(file: s3, expandable: expandable))
        // Laid out as drawing it would.
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
        var asked: [ContextExpansion] = []
        view.onExpand = { asked.append($0) }

        // The third hunk's header sits 100pt down the view when its up arrow is clicked.
        let header = try #require(view.rendered).hunkRows[2]
        view.scroll(NSPoint(x: 0, y: try top(ofRow: header, in: view) - 100))
        try click("↑", onRow: header, in: view)
        #expect(asked == [ContextExpansion(hunk: 2, direction: .above)])

        let expanded = s3.expanding(asked[0], newFile: file)
        view.show(RenderedDiff(file: expanded, expandable: expandable), keepingPlace: true)

        let shown = try #require(view.rendered)
        #expect(try top(ofRow: shown.hunkRows[2], in: view) - view.visibleRect.minY == 100)
        // The revealed lines follow it, numbered on both sides and coloured like the rest.
        let revealed = shown.hunkRows[2] + 1
        #expect(shown.rowAnchors[revealed] == DiffAnchor(path: s3.path, side: .right, line: 46))
        #expect((shown.text.string as NSString).substring(with: NSRange(location: shown.rowStarts[revealed], length: 13)).hasPrefix(" 49   46"))
        let runs = try #require(shown.syntax).runs()
        #expect(runs.contains { NSLocationInRange($0.range.location, NSRange(location: shown.rowStarts[revealed], length: shown.rowStarts[revealed + 1] - shown.rowStarts[revealed])) })
    }

    @Test func hidingRevealedLinesKeepsTheFirstCodeLineInViewWhereItWas() throws {
        let s3 = try fixtureFile("s3.go")
        let file = newFile(for: s3)
        let expandable = ExpandableContext(newLineCount: file.count)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        scroll.documentView = view
        let expanded = s3.expanding(ContextExpansion(hunk: 2, direction: .above), newFile: file)
        view.show(RenderedDiff(file: expanded, expandable: expandable))
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))

        let shown = try #require(view.rendered)
        let plain = RenderedDiff(file: s3, expandable: expandable)
        let kept = try #require((shown.hunkRows[2] + 1..<shown.rowStarts.count).first { row in
            shown.rowAnchors[row].map(plain.rowAnchors.contains) ?? false
        })
        // Scrolled so the top of the view is at the last revealed line, which hiding them drops.
        view.scroll(NSPoint(x: 0, y: try top(ofRow: kept - 1, in: view)))
        let anchor = try #require(shown.rowAnchors[kept])
        let offset = try top(ofRow: kept, in: view) - view.visibleRect.minY

        view.show(plain, keepingPlace: true)
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))

        let row = try #require(plain.rowAnchors.firstIndex(of: anchor))
        #expect(try top(ofRow: row, in: view) - view.visibleRect.minY == offset)
    }
}

/// The expand controls on a row, by the glyph each shows.
@MainActor
private func controls(onRow row: Int, of rendered: RenderedDiff) -> [String: ContextExpansion] {
    let end = row + 1 < rendered.rowStarts.count ? rendered.rowStarts[row + 1] : rendered.text.length
    var found: [String: ContextExpansion] = [:]
    rendered.text.enumerateAttribute(.diffExpansion, in: NSRange(location: rendered.rowStarts[row], length: end - rendered.rowStarts[row])) { value, range, _ in
        guard let expansion = value as? ContextExpansion else { return }
        found[(rendered.text.string as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)] = expansion
    }
    return found
}

@MainActor
private func top(ofRow row: Int, in view: DiffTextView) throws -> CGFloat {
    let layoutManager = try #require(view.layoutManager)
    let start = try #require(view.rendered).rowStarts[row]
    return layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil).minY + view.textContainerOrigin.y
}

/// Sends a mouse down at the middle of `glyph` on the row, as a click arrives.
@MainActor
private func click(_ glyph: String, onRow row: Int, in view: DiffTextView) throws {
    let rendered = try #require(view.rendered)
    let layoutManager = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    let found = (rendered.text.string as NSString).range(of: glyph, range: NSRange(location: rendered.rowStarts[row], length: rendered.rowStarts[row + 1] - rendered.rowStarts[row]))
    let bounds = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: found, actualCharacterRange: nil), in: container)
    let point = view.convert(NSPoint(x: bounds.midX + view.textContainerOrigin.x, y: bounds.midY + view.textContainerOrigin.y), to: nil)
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    view.mouseDown(with: event)
}
