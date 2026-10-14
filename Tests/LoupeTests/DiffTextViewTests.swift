import AppKit
import LoupeCore
import Testing

@MainActor
struct DiffTextViewTests {
    @Test func clickingARowReportsWhereACommentWouldAttach() throws {
        let rendered = try RenderedDiff(file: goMod())
        let text = rendered.text.string as NSString

        func anchor(onRowContaining needle: String) -> DiffAnchor? {
            rendered.anchor(at: text.range(of: needle).location)
        }

        #expect(anchor(onRowContaining: "@@ -7,7") == nil)
        #expect(anchor(onRowContaining: "require (") == DiffAnchor(path: "go.mod", side: .right, line: 7))
        #expect(anchor(onRowContaining: "aws-sdk-go v1.49.23") == DiffAnchor(path: "go.mod", side: .left, line: 10))
        #expect(anchor(onRowContaining: "transfermanager v0.4.14") == DiffAnchor(path: "go.mod", side: .right, line: 10))
    }

    @Test func copyingLeavesOutLineNumbersAndMarkers() throws {
        let view = DiffTextView.make()
        view.show(try RenderedDiff(file: goMod()))
        let text = view.string as NSString
        let start = text.range(of: "@@ -7,7").location
        let end = NSMaxRange(text.lineRange(for: NSRange(location: text.range(of: "transfermanager").location, length: 0)))
        view.setSelectedRange(NSRange(location: start, length: end - start))

        let board = NSPasteboard(name: NSPasteboard.Name("LoupeTests-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        #expect(view.writeSelection(to: board, type: .string))
        #expect(board.string(forType: .string) == """
        @@ -7,7 +7,7 @@ retract v0.657.0
        require (
        \tgithub.com/DATA-DOG/go-sqlmock v1.5.2
        \tgithub.com/actgardner/gogen-avro/v7 v7.0.0
        \tgithub.com/aws/aws-sdk-go v1.49.23
        \tgithub.com/aws/aws-sdk-go-v2/feature/s3/transfermanager v0.4.14

        """)
    }

    @Test func paintsAddedAndDeletedRowsAcrossTheFullWidth() throws {
        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 1600, height: 400)
        let rendered = try RenderedDiff(file: goMod())
        view.show(rendered)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)

        // Sample far right of each row, well past the end of its text.
        func colorAtRightEdge(ofRowContaining needle: String) throws -> NSColor {
            let index = (rendered.text.string as NSString).range(of: needle).location
            let layoutManager = try #require(view.layoutManager)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: index), effectiveRange: nil)
            let y = Int(rect.midY + view.textContainerOrigin.y)
            // Map by the bitmap's own size: laying out to draw it can resize the view.
            return try #require(bitmap.colorAt(x: bitmap.pixelsWide - 4, y: y * bitmap.pixelsHigh / Int(bitmap.size.height)))
        }

        let added = try colorAtRightEdge(ofRowContaining: "transfermanager")
        let deleted = try colorAtRightEdge(ofRowContaining: "aws-sdk-go v1.49.23")
        let context = try colorAtRightEdge(ofRowContaining: "require (")
        #expect(added.greenComponent > added.redComponent)
        #expect(deleted.redComponent > deleted.greenComponent)
        #expect(context.redComponent == context.greenComponent)
    }

    @Test func wrappedRowsHangUnderTheCodeAndKeepTheirAnchorAndBackground() throws {
        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        let rendered = try RenderedDiff(file: goMod())
        view.show(rendered)
        let layoutManager = try #require(view.layoutManager)
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        let text = rendered.text.string as NSString

        // The added row's last character sits on a continuation line, below where the row starts.
        let row = text.lineRange(for: NSRange(location: text.range(of: "transfermanager").location, length: 0))
        let first = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: row.location), effectiveRange: nil)
        let lastGlyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(row) - 2)
        let continuation = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        #expect(continuation.minY > first.minY)

        // It starts two columns in from the code, past the gutter, so it reads as a continuation.
        var continuationGlyphs = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: &continuationGlyphs)
        var gutter = NSRange()
        _ = rendered.text.attribute(.diffGutter, at: row.location, longestEffectiveRange: &gutter, in: row)
        let codeStart = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: NSMaxRange(gutter))).x
        let column = ("0" as NSString).size(withAttributes: [.font: view.font as Any]).width
        #expect(layoutManager.location(forGlyphAt: continuationGlyphs.location).x == codeStart + column * 2)

        // Clicking it gives the row's anchor, and its background spans the width.
        let origin = view.textContainerOrigin
        let point = NSPoint(x: origin.x + continuation.minX + codeStart + 4, y: origin.y + continuation.midY)
        #expect(rendered.anchor(at: view.characterIndexForInsertion(at: point)) == DiffAnchor(path: "go.mod", side: .right, line: 10))

        let line = continuation.offsetBy(dx: origin.x, dy: origin.y)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: line))
        view.cacheDisplay(in: line, to: bitmap)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh / 2))
        #expect(color.greenComponent > color.redComponent)
    }

    @Test func lineNumbersSitInRightAlignedColumnsBesideTheCode() throws {
        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 1600, height: 400)
        let rendered = try RenderedDiff(file: goMod())
        view.show(rendered)
        let layoutManager = try #require(view.layoutManager)
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        let text = rendered.text.string as NSString

        func row(containing needle: String) -> NSRange {
            text.lineRange(for: NSRange(location: text.range(of: needle).location, length: 0))
        }
        func x(at index: Int) -> CGFloat {
            layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: index)).x
        }
        // The x of a number's last digit in the row's gutter; backwards finds the new side's.
        func numberEnd(_ number: Int, inRowContaining needle: String, newSide: Bool = false) -> CGFloat {
            let found = text.range(of: String(number), options: newSide ? .backwards : [], range: NSRange(location: row(containing: needle).location, length: 12))
            return x(at: NSMaxRange(found) - 1)
        }
        func codeStart(ofRowContaining needle: String) -> CGFloat {
            var gutter = NSRange()
            _ = rendered.text.attribute(.diffGutter, at: row(containing: needle).location, longestEffectiveRange: &gutter, in: row(containing: needle))
            return x(at: NSMaxRange(gutter))
        }

        // One- and two-digit numbers end in the same place, on each side.
        #expect(numberEnd(8, inRowContaining: "go-sqlmock") == numberEnd(10, inRowContaining: "aws-sdk-go v1.49.23"))
        #expect(numberEnd(8, inRowContaining: "go-sqlmock", newSide: true) == numberEnd(10, inRowContaining: "transfermanager", newSide: true))
        #expect(numberEnd(8, inRowContaining: "go-sqlmock") < numberEnd(8, inRowContaining: "go-sqlmock", newSide: true))

        // Hunk headers and every kind of row start their text in the same column.
        let code = codeStart(ofRowContaining: "require (")
        #expect(codeStart(ofRowContaining: "@@ -7,7") == code)
        #expect(codeStart(ofRowContaining: "aws-sdk-go v1.49.23") == code)
        #expect(codeStart(ofRowContaining: "transfermanager") == code)

        // Clicking a line number gives its row's anchor.
        let deleted = row(containing: "aws-sdk-go v1.49.23")
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: deleted.location), effectiveRange: nil)
        let point = NSPoint(x: view.textContainerOrigin.x + numberEnd(10, inRowContaining: "aws-sdk-go v1.49.23"), y: view.textContainerOrigin.y + fragment.midY)
        #expect(rendered.anchor(at: view.characterIndexForInsertion(at: point)) == DiffAnchor(path: "go.mod", side: .left, line: 10))
    }

    @Test func emphasisesTheWordsThatChangedWithinAModifiedLine() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/fetch.go b/fetch.go
        --- a/fetch.go
        +++ b/fetch.go
        @@ -1,8 +1,8 @@
         func load(ctx context.Context, id string) error {
        -\treturn fetch(ctx, id)
        +\treturn fetchAll(ctx, id)
        -\tx := 1
        +\tlog.Println("nothing alike")
         \t// realigned by gofmt
        -\tMatch:    query.All(a)
        +\tMatchSQL: query.All(a)
         }

        """).files.first)
        let rendered = RenderedDiff(file: file)
        let text = rendered.text.string as NSString

        func emphasised(_ needle: String, after start: String) -> Bool {
            let from = text.range(of: start).location
            let found = text.range(of: needle, range: NSRange(location: from, length: text.length - from))
            return rendered.text.attribute(.diffEmphasis, at: found.location, effectiveRange: nil) != nil
        }

        #expect(emphasised("fetch(", after: "-\t"))
        #expect(emphasised("fetchAll", after: "+\t"))
        #expect(!emphasised("return", after: "-\t"))
        #expect(!emphasised("ctx, id", after: "+\t"))
        // A pair with nothing in common is a replacement, not an edit, so no word stands out.
        #expect(!emphasised("x := 1", after: "x := 1"))
        #expect(!emphasised("log.Println", after: "log.Println"))
        // Realigned whitespace isn't emphasised, only the word that changed.
        #expect(emphasised("Match:", after: "Match:"))
        #expect(!emphasised("    query", after: "Match:"))
        #expect(emphasised("MatchSQL:", after: "MatchSQL:"))
        #expect(!emphasised(" query", after: "MatchSQL:"))
    }
}

private func goMod() throws -> FileDiff {
    try #require(Diff(parsing: fixture("atrium-2912.diff")).files.first)
}
