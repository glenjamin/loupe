import LoupeModel
import Testing

/// What a `:` and part of a name offers in a comment box, as github.com's does.
struct EmojiTests {
    let all = ["tada", "taco", "potato", "tangerine", "+1", "shipit", "stuck_out_tongue_winking_eye"].map { Emoji(name: $0, character: $0 == "shipit" ? nil : "x") }

    @Test func namesStartingWithWhatsTypedComeFirstShortestFirstThenThoseWithItInside() {
        #expect(Emoji.matches(all, for: "ta").map(\.name) == ["taco", "tada", "tangerine", "potato"])
        #expect(Emoji.matches(all, for: "TA").map(\.name) == ["taco", "tada", "tangerine", "potato"], "ignoring case")
        #expect(Emoji.matches(all, for: "wink").map(\.name) == ["stuck_out_tongue_winking_eye"])
        #expect(Emoji.matches(all, for: "+").map(\.name) == ["+1"])
        #expect(Emoji.matches(all, for: "ta", limit: 2).map(\.name) == ["taco", "tada"])
        #expect(Emoji.matches(all, for: "").isEmpty)
    }

    @Test func aCompletionPutsInTheCharacterOrForGitHubsOwnItsName() {
        #expect(Emoji(name: "tada", character: "🎉").insertion == "🎉")
        #expect(Emoji(name: "shipit", character: nil).insertion == ":shipit:")
    }
}
