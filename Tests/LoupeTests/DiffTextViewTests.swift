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
            return try #require(bitmap.colorAt(x: bitmap.pixelsWide - 4, y: y * bitmap.pixelsHigh / Int(view.bounds.height)))
        }

        let added = try colorAtRightEdge(ofRowContaining: "transfermanager")
        let deleted = try colorAtRightEdge(ofRowContaining: "aws-sdk-go v1.49.23")
        let context = try colorAtRightEdge(ofRowContaining: "require (")
        #expect(added.greenComponent > added.redComponent)
        #expect(deleted.redComponent > deleted.greenComponent)
        #expect(context.redComponent == context.greenComponent)
    }
}

private func goMod() throws -> FileDiff {
    try #require(Diff(parsing: fixture("atrium-2912.diff")).files.first)
}
