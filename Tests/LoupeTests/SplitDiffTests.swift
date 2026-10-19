import AppKit
import LoupeCore
import Testing

@MainActor
struct SplitDiffTests {
    @Test func pairsEachRunOfDeletionsWithTheAdditionsAfterItAndLeavesTheRestEmpty() throws {
        let rendered = RenderedDiff(file: try sample(), layout: .split)

        #expect(rows(of: rendered) == [
            .header,
            .row(left: 1, right: 1),
            .row(left: 2, right: 2),
            .row(left: 3, right: nil),
            .row(left: 4, right: nil),
            .row(left: 5, right: 3),
            .row(left: 6, right: 4),
            .row(left: nil, right: 5),
            .row(left: 7, right: 6),
            .header,
            .row(left: 20, right: 19),
            .row(left: nil, right: 20),
            .row(left: nil, right: 21),
        ])
        // Each side's lines are commented on from that side, as GitHub's LEFT and RIGHT.
        for (index, side) in rendered.rowSides.enumerated() where rendered.rowAnchors[index] != nil {
            #expect(rendered.rowAnchors[index]?.side == side)
        }
    }

    @Test func eachSideSitsInItsHalfAndTheRowIsAsTallAsItsTallerSide() throws {
        let (view, rendered) = try shown(width: 900)
        let layoutManager = try #require(view.layoutManager)
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        let text = rendered.text.string as NSString

        func fragment(of needle: String, last: Bool = false) -> NSRect {
            let found = text.range(of: needle)
            let index = last ? NSMaxRange(found) - 1 : found.location
            return layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: index), effectiveRange: nil)
        }
        func x(of needle: String) -> CGFloat {
            layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: text.range(of: needle).location)).x
        }

        // The deleted line wraps within the left half; the line it became sits beside it, on one line.
        let deleted = fragment(of: "var wording = \"old\"")
        let deletedEnd = fragment(of: "wrap here", last: true)
        let added = fragment(of: "var wording = \"new\"")
        #expect(deleted.maxX <= 450)
        #expect(added.minX >= 450)
        #expect(added.minY == deleted.minY)
        #expect(deletedEnd.minY > deleted.minY)
        // The next row starts below the taller side.
        #expect(fragment(of: "\tdropped").minY >= deletedEnd.maxY)

        // Each side's code starts in the same column of its half, and continuations hang under it.
        #expect(added.minX - 450 + x(of: "var wording = \"new\"") == deleted.minX + x(of: "var wording = \"old\""))
        #expect(deletedEnd.minX > deleted.minX)
    }

    @Test func clickingASideGivesThatSidesLineEvenBesideTheOtherSidesWrappedLines() throws {
        let (view, rendered) = try shown(width: 900)
        let layoutManager = try #require(view.layoutManager)
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        let text = rendered.text.string as NSString
        func fragment(of index: Int) -> NSRect {
            layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: index), effectiveRange: nil)
        }
        let origin = view.textContainerOrigin
        func anchor(atX x: CGFloat, y: CGFloat) -> DiffAnchor? {
            rendered.anchor(at: view.characterIndexForInsertion(at: NSPoint(x: origin.x + x, y: origin.y + y)))
        }

        // Right of the middle, level with the deleted line's continuation, is the added line.
        let wrapped = fragment(of: NSMaxRange(text.range(of: "wrap here")) - 1)
        #expect(anchor(atX: 700, y: wrapped.midY) == DiffAnchor(path: "split.go", side: .right, line: 2))
        #expect(anchor(atX: 200, y: wrapped.midY) == DiffAnchor(path: "split.go", side: .left, line: 2))
        // An unchanged line is the old line on the left and the new on the right.
        let context = fragment(of: text.range(of: "package split").location)
        #expect(anchor(atX: 200, y: context.midY) == DiffAnchor(path: "split.go", side: .left, line: 1))
        #expect(anchor(atX: 700, y: context.midY) == DiffAnchor(path: "split.go", side: .right, line: 1))
    }

    @Test func hoveringEitherSideOffersAPlusAtThatSidesGutterForThatSidesLine() throws {
        let (view, rendered) = try shown(width: 900)
        let layoutManager = try #require(view.layoutManager)
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        let old = DiffAnchor(path: "split.go", side: .left, line: 1)
        let new = DiffAnchor(path: "split.go", side: .right, line: 1)
        view.commentableAnchors = [old, new]
        var asked: [DiffAnchor] = []
        view.onComment = { asked.append($0) }
        let index = (rendered.text.string as NSString).range(of: "package split").location
        let row = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: index), effectiveRange: nil)

        func hover(atX x: CGFloat) throws {
            let point = view.convert(NSPoint(x: view.textContainerOrigin.x + x, y: view.textContainerOrigin.y + row.midY), to: nil)
            view.mouseMoved(with: try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        }
        try hover(atX: 200)
        #expect(!view.commentButton.isHidden)
        #expect(view.commentButton.frame.minX < 450)
        view.commentButton.performClick(nil)
        try hover(atX: 700)
        #expect(!view.commentButton.isHidden)
        #expect(view.commentButton.frame.minX >= 450)
        view.commentButton.performClick(nil)
        #expect(asked == [old, new])
    }

    @Test func selectingOnOneSideKeepsToItsCodeAndCopiesOnlyThat() throws {
        let (view, rendered) = try shown(width: 900)
        let text = rendered.text.string as NSString
        // From within the first deleted line to the end of the deletions after the addition.
        let start = text.range(of: "wording").location
        let end = NSMaxRange(text.range(of: "gone too"))
        view.setSelectedRange(NSRange(location: start, length: end - start))

        // Nothing on the right, nor any line number, is selected.
        let selected = view.selectedRanges.map { text.substring(with: $0.rangeValue) }
        #expect(!selected.contains { $0.contains("new") || $0.contains("kept") })
        #expect(selected.first == "wording = \"old\" // that runs on and on until it has to wrap here")

        let board = NSPasteboard(name: NSPasteboard.Name("LoupeTests-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        #expect(view.writeSelection(to: board, type: .string))
        #expect(board.string(forType: .string) == """
        wording = "old" // that runs on and on until it has to wrap here
        \tdropped
        \t
        \tgone
        \tgone too
        """)

        // The same on the right: the added lines alone, without the deletions beside them.
        let right = text.range(of: "var wording = \"new\"").location
        let rightEnd = NSMaxRange(text.range(of: "added()"))
        view.setSelectedRange(NSRange(location: right, length: rightEnd - right))
        board.clearContents()
        #expect(view.writeSelection(to: board, type: .string))
        #expect(board.string(forType: .string) == """
        var wording = "new" // that runs on
        \tkept()
        \tchanged()
        \tadded()
        """)
    }

    @Test func threadsGoUnderTheRowOfTheirLineOnEitherSideAcrossTheWholeWidth() throws {
        let blocks = [
            DiffBlock(id: "left", placement: .after(side: .left, line: 4), height: 50),
            DiffBlock(id: "right", placement: .after(side: .right, line: 3), height: 50),
            DiffBlock(id: "context", placement: .after(side: .left, line: 7), height: 50),
        ]
        let rendered = RenderedDiff(file: try sample(), blocks: blocks, layout: .split)
        // The row above a block: the last side of a row before it, past any other blocks.
        func row(above block: String) throws -> SplitRow {
            var right = try #require(rendered.blockRows[block]) - 1
            while rendered.rowSides[right] == nil { right -= 1 }
            return splitRow(startingAt: right - 1, in: rendered)
        }
        #expect(try row(above: "left") == .row(left: 4, right: nil))
        #expect(try row(above: "right") == .row(left: 5, right: 3))
        #expect(try row(above: "context") == .row(left: 7, right: 6))

        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.show(rendered)
        let layoutManager = try #require(view.layoutManager)
        let range = try #require(rendered.range(ofBlock: "left"))
        layoutManager.ensureLayout(forCharacterRange: range)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        #expect(fragment.minX == 0)
        #expect(fragment.width >= 899)
        #expect(fragment.height == 50)
    }

    @Test func paintsEachSidesTintAcrossItsHalfAndGreysAnEmptySide() throws {
        let (view, rendered) = try shown(width: 900)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let layoutManager = try #require(view.layoutManager)
        let text = rendered.text.string as NSString
        func color(x: CGFloat, onLineOf needle: String, last: Bool = false) throws -> NSColor {
            let found = text.range(of: needle)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: last ? NSMaxRange(found) - 1 : found.location), effectiveRange: nil)
            let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
            return try #require(bitmap.colorAt(x: Int(x * scale), y: Int((rect.midY + view.textContainerOrigin.y) * scale)))
        }
        // Beside the deleted line's continuation, the added line's tint carries on down the right.
        let deleted = try color(x: 440, onLineOf: "wrap here", last: true)
        let added = try color(x: 890, onLineOf: "wrap here", last: true)
        #expect(deleted.redComponent > deleted.greenComponent)
        #expect(added.greenComponent > added.redComponent)
        // A deletion with nothing beside it has a grey right side.
        let empty = try color(x: 890, onLineOf: "\tdropped")
        #expect(empty.redComponent < 0.99)
        #expect(abs(empty.redComponent - empty.greenComponent) < 0.03)
    }

    @Test func highlightsAndEmphasisesEachSideAsUnified() throws {
        let rendered = RenderedDiff(file: try sample(), layout: .split)
        let text = rendered.text.string as NSString
        let runs = try #require(rendered.syntax).runs()
        func coloured(_ needle: String, options: NSString.CompareOptions = []) -> Bool {
            let found = text.range(of: needle, options: options)
            return runs.contains { NSLocationInRange(found.location, $0.range) }
        }
        // Unchanged lines are coloured on both sides, changed ones on theirs.
        #expect(coloured("package"))
        #expect(coloured("package", options: .backwards))
        #expect(coloured("var"))
        #expect(coloured("var", options: .backwards))

        // A deletion beside the one addition it became has its changed words picked out.
        let edit = RenderedDiff(file: try #require(Diff(parsing: """
        diff --git a/fetch.go b/fetch.go
        --- a/fetch.go
        +++ b/fetch.go
        @@ -1,1 +1,1 @@
        -\treturn fetch(ctx, id)
        +\treturn fetchAll(ctx, id)

        """).files.first), layout: .split)
        let editText = edit.text.string as NSString
        func emphasised(_ needle: String) -> Bool {
            edit.text.attribute(.diffEmphasis, at: editText.range(of: needle).location, effectiveRange: nil) != nil
        }
        #expect(emphasised("fetch("))
        #expect(emphasised("fetchAll"))
        #expect(!emphasised("return"))
    }

    @Test func fallsBackToUnifiedWhereTwoSidesWouldBeTooNarrow() throws {
        let file = try sample()
        #expect(DiffLayout.splitFits(file, width: 1200))
        #expect(!DiffLayout.splitFits(file, width: 700))
    }
}

/// A row of a split diff by its sides' line numbers, old and new, or a hunk header.
private enum SplitRow: Equatable {
    case header
    case row(left: Int?, right: Int?)
}

private func rows(of rendered: RenderedDiff) -> [SplitRow] {
    var rows: [SplitRow] = []
    var index = 0
    while index < rendered.rowStarts.count {
        if rendered.hunkRows.contains(index) {
            rows.append(.header)
            index += 1
        } else if rendered.rowSides[index] == .left {
            rows.append(splitRow(startingAt: index, in: rendered))
            index += 2
        } else {
            index += 1
        }
    }
    return rows
}

private func splitRow(startingAt left: Int, in rendered: RenderedDiff) -> SplitRow {
    .row(left: rendered.rowAnchors[left]?.line, right: rendered.rowAnchors[left + 1]?.line)
}

@MainActor
private func shown(width: CGFloat) throws -> (DiffTextView, RenderedDiff) {
    let view = DiffTextView.make()
    view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
    let rendered = RenderedDiff(file: try sample(), layout: .split)
    view.show(rendered)
    return (view, rendered)
}

/// Runs of deletions and additions of unequal lengths around unchanged lines, with a deleted
/// line long enough to wrap in half of a 900pt view beside the short line it became.
private func sample() throws -> FileDiff {
    try #require(Diff(parsing: """
    diff --git a/split.go b/split.go
    --- a/split.go
    +++ b/split.go
    @@ -1,7 +1,6 @@
     package split
    -var wording = "old" // that runs on and on until it has to wrap here
    -\tdropped
    -\t
    +var wording = "new" // that runs on
    -\tgone
    -\tgone too
    +\tkept()
    +\tchanged()
    +\tadded()
     func main() {}
    @@ -20,1 +19,3 @@
     }
    +// more
    +// at the end

    """).files.first)
}
