import LoupeCore
import Testing

struct CodeWordBoundaryTests {
    @Test func memberAccessStopsAtEachSideOfTheDot() {
        #expect(stops("obj.Field|", .left) == ["obj.|Field", "obj|.Field", "|obj.Field"])
        #expect(stops("|obj.Field", .right) == ["obj|.Field", "obj.|Field", "obj.Field|"])
    }

    @Test func aCallIsSteppedThroughByItsWordsAndPunctuation() {
        #expect(stops("foo(bar, baz)|", .left) == [
            "foo(bar, baz|)",
            "foo(bar, |baz)",
            "foo(bar|, baz)",
            "foo(|bar, baz)",
            "foo|(bar, baz)",
            "|foo(bar, baz)",
        ])
        #expect(stops("|foo(bar, baz)", .right) == [
            "foo|(bar, baz)",
            "foo(|bar, baz)",
            "foo(bar|, baz)",
            "foo(bar,| baz)",
            "foo(bar, baz|)",
            "foo(bar, baz)|",
        ])
    }

    @Test func spacesAreSkippedRatherThanStoppedAt() {
        #expect(stops("let  total_count = 42  |", .left) == [
            "let  total_count = |42  ",
            "let  total_count |= 42  ",
            "let  |total_count = 42  ",
            "|let  total_count = 42  ",
        ])
        #expect(stops("|  let x", .right) == ["  let| x", "  let x|"])
    }

    @Test func theEndsOfTheTextStayPut() {
        #expect(move("|obj.Field", .left) == "|obj.Field")
        #expect(move("obj.Field|", .right) == "obj.Field|")
        #expect(move("|", .left) == "|")
        #expect(move("   |", .left) == "|   ")
        #expect(move("|   ", .right) == "   |")
    }

    @Test func unicodeLettersAreWordCharacters() {
        #expect(stops("café.naïve|", .left) == ["café.|naïve", "café|.naïve", "|café.naïve"])
        #expect(stops("|größe→Ωmega", .right) == ["größe|→Ωmega", "größe→|Ωmega", "größe→Ωmega|"])
        #expect(stops("x = 👍🏽|", .left) == ["x = |👍🏽", "x |= 👍🏽", "|x = 👍🏽"])
    }
}

/// Every stop from the caret marked `|` in `text`, moving one way until the text's end.
private func stops(_ text: String, _ direction: CodeWordDirection) -> [String] {
    var result: [String] = []
    var current = text
    while true {
        let next = move(current, direction)
        if next == current { return result }
        result.append(next)
        current = next
    }
}

/// `text` with its `|` caret moved by one code word.
private func move(_ text: String, _ direction: CodeWordDirection) -> String {
    let parts = text.split(separator: "|", omittingEmptySubsequences: false)
    let plain = parts.joined()
    let moved = codeWordBoundary(in: plain, from: parts[0].utf16.count, direction)
    let index = String.Index(utf16Offset: moved, in: plain)
    return String(plain[..<index]) + "|" + String(plain[index...])
}
