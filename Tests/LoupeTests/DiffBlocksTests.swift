import AppKit
import LoupeCore
import Testing

@MainActor
struct DiffBlocksTests {
    @Test func blocksGetARowOfTheirHeightUnderTheirLineAndCopiesLeaveThemOut() throws {
        let goMod = try fixtureFile("go.mod")
        let blocks = [
            DiffBlock(id: "added", placement: .after(side: .right, line: 10), height: 50),
            DiffBlock(id: "deleted", placement: .after(side: .left, line: 10), height: 30),
            DiffBlock(id: "unchanged", placement: .after(side: .right, line: 7), height: 30),
            DiffBlock(id: "missing", placement: .after(side: .right, line: 9_999), height: 30),
            DiffBlock(id: "end", placement: .end, height: 30),
        ]
        let rendered = RenderedDiff(file: goMod, blocks: blocks)
        let text = rendered.text.string as NSString

        func row(containing needle: String) -> Int? {
            rendered.row(at: text.range(of: needle).location)
        }
        #expect(rendered.blockRows["unchanged"] == row(containing: "require (").map { $0 + 1 })
        #expect(rendered.blockRows["deleted"] == row(containing: "aws-sdk-go v1.49.23").map { $0 + 1 })
        #expect(rendered.blockRows["added"] == row(containing: "transfermanager v0.4.14").map { $0 + 1 })
        // A line the diff doesn't have puts its block at the end, in the order given.
        #expect(rendered.blockRows["missing"] == rendered.rowStarts.count - 2)
        #expect(rendered.blockRows["end"] == rendered.rowStarts.count - 1)
        #expect(rendered.blockRows.values.allSatisfy { rendered.rowAnchors[$0] == nil })
        // Pairs of modified lines are still compared word by word with a block between them.
        let changed = text.range(of: "4d2e42eff668")
        #expect(rendered.text.attribute(.diffEmphasis, at: changed.location, effectiveRange: nil) != nil)

        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.show(rendered)
        let layoutManager = try #require(view.layoutManager)
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        func fragment(_ id: String) throws -> NSRect {
            let range = try #require(rendered.range(ofBlock: id))
            return layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        }
        #expect(try fragment("added").height == 50)

        // A view laid over a block sits on its row, and follows it when one above grows.
        let card = NSView()
        view.setBlockViews(["added": card])
        #expect(card.frame.minY == (try fragment("added").minY) + view.textContainerOrigin.y)
        #expect(card.frame.height == 50)
        view.setHeight(80, ofBlock: "deleted")
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        #expect(try fragment("deleted").height == 80)
        #expect(card.frame.minY == (try fragment("added").minY) + view.textContainerOrigin.y)
        #expect(card.superview === view)
        view.setBlockViews([:])
        #expect(card.superview == nil)

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
}
