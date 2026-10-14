import LoupeCore
import Testing

struct ContextExpansionTests {
    @Test func expandingAboveTheFirstHunkStopsAtTheFilesFirstLine() throws {
        let goMod = try fixtureFile("go.mod")
        let file = newFile(for: goMod)

        let expanded = goMod.expanding(ContextExpansion(hunk: 0, direction: .above), newFile: file)

        let hunk = expanded.hunks[0]
        #expect(hunk.header == "@@ -1,13 +1,13 @@ retract v0.657.0")
        #expect(hunk.lines.prefix(7).map(\.kind) == (1...7).map { .context(old: $0, new: $0) })
        #expect(hunk.lines[0].text == file[0])
        #expect(expanded.hiddenLines(above: 0) == 0)
        #expect(expanded.hunks.count == goMod.hunks.count)
    }

    @Test func revealingAWholeGapMergesTheHunksAroundIt() throws {
        let s3 = try fixtureFile("s3.go")
        let file = newFile(for: s3)
        #expect(s3.hiddenLines(above: 1) == 2)

        let expanded = s3.expanding(ContextExpansion(hunk: 1, direction: .above, lines: nil), newFile: file)

        #expect(expanded.hunks.count == s3.hunks.count - 1)
        // The earlier hunk's function context is kept.
        #expect(expanded.hunks[0].header == "@@ -2,23 +2,20 @@ package pipetest")
        let joined = expanded.hunks[0].lines
        let gap = try #require(joined.firstIndex { $0.newLine == 14 })
        #expect(joined[gap] == DiffLine(kind: .context(old: 15, new: 14), text: file[13]))
        #expect(joined[gap + 1] == DiffLine(kind: .context(old: 16, new: 15), text: file[14]))
        #expect(joined[gap + 2].kind == .context(old: 17, new: 16), "the later hunk's own first line follows")
    }

    @Test func numbersRevealedLinesOnBothSidesAcrossUnequalChanges() throws {
        let s3 = try fixtureFile("s3.go")
        let file = newFile(for: s3)
        // Two lines were added and five removed before this gap, so old runs three ahead.
        #expect(s3.hiddenLines(above: 2) == 44)

        let above = s3.expanding(ContextExpansion(hunk: 2, direction: .above), newFile: file)
        #expect(above.hunks[2].header == "@@ -49,27 +46,27 @@ func (f *Rocket) ResetRibbon() {")
        #expect(above.hunks[2].lines.prefix(20).map(\.kind) == (46...65).map { .context(old: $0 + 3, new: $0) })
        #expect(above.hiddenLines(above: 2) == 24)

        let below = above.expanding(ContextExpansion(hunk: 1, direction: .below), newFile: file)
        #expect(below.hunks[1].header == "@@ -17,28 +16,26 @@ const fiberSketch = RefreshQuill(fencePlank)")
        #expect(below.hunks[1].lines.suffix(20).map(\.kind) == (22...41).map { .context(old: $0 + 3, new: $0) })
        #expect(below.hiddenLines(above: 2) == 4)

        let closed = below.expanding(ContextExpansion(hunk: 2, direction: .above), newFile: file)
        #expect(closed.hunks.count == s3.hunks.count - 1)
        #expect(closed.hunks[1].lines.map(\.kind).contains(.context(old: 45, new: 42)))
    }

    @Test func expandingBelowTheLastHunkStopsAtTheFilesEnd() throws {
        let s3 = try fixtureFile("s3.go")
        let file = newFile(for: s3, trailing: 7)
        #expect(s3.hiddenLinesAfterLastHunk(newLineCount: file.count) == 7)

        let expanded = s3.expanding(ContextExpansion(hunk: 3, direction: .below), newFile: file)

        let last = try #require(expanded.hunks.last)
        #expect(last.lines.last == DiffLine(kind: .context(old: 90, new: file.count), text: file[file.count - 1]))
        #expect(expanded.hiddenLinesAfterLastHunk(newLineCount: file.count) == 0)
    }

    @Test func expandingEveryGapLeavesOneHunkNumberedStraightThrough() throws {
        let diff = try Diff(parsing: fixture("atrium-2912.diff"))
        for original in diff.files {
            let file = newFile(for: original)
            var expanded = original
            while expanded.hunks.count > 1 || expanded.hiddenLines(above: 0) > 0 {
                expanded = expanded.expanding(ContextExpansion(hunk: expanded.hunks.count - 1, direction: .above), newFile: file)
                for hunk in expanded.hunks {
                    let declared = declaredCounts(hunk.header)
                    #expect(hunk.lines.count { $0.oldLine != nil } == declared.old && hunk.lines.count { $0.newLine != nil } == declared.new, "\(original.path) \(hunk.header)")
                }
            }
            expanded = expanded.expanding(ContextExpansion(hunk: 0, direction: .below, lines: nil), newFile: file)

            let lines = try #require(expanded.hunks.first).lines
            #expect(lines.compactMap(\.newLine) == Array(1...file.count), "\(original.path)")
            #expect(lines.compactMap(\.oldLine) == Array(1...(lines.compactMap(\.oldLine).count)), "\(original.path)")
            #expect(lines.filter { $0.newLine != nil }.map(\.text) == file, "\(original.path)")
            #expect(expanded.additions == original.additions && expanded.deletions == original.deletions)
        }
    }
}

func fixtureFile(_ name: String) throws -> FileDiff {
    try #require(Diff(parsing: fixture("atrium-2912.diff")).files.first { $0.path.hasSuffix(name) })
}

/// A new side for `file`'s diff: its hunks' lines where they fall, and a placeholder for each
/// line the diff doesn't show, with `trailing` more after the last hunk.
func newFile(for file: FileDiff, trailing: Int = 30) -> [String] {
    let end = file.hunks.last.map { $0.newLines.upperBound - 1 } ?? 0
    var lines = (1...end + trailing).map { "// unchanged line \($0)" }
    for line in file.hunks.flatMap(\.lines) {
        if let new = line.newLine { lines[new - 1] = line.text }
    }
    return lines
}
