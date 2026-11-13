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

/// What an `@` and part of a login or name offers in a comment box.
struct MentionMatchingTests {
    let people = [
        Reviewer(kind: .user, nodeId: nil, login: "kit-vance", name: "Kit Vance"),
        Reviewer(kind: .user, nodeId: nil, login: "vanessa", name: "Nessa Kitt"),
        Reviewer(kind: .user, nodeId: nil, login: "eharcourt"),
        Reviewer(kind: .team, nodeId: nil, login: "acme/devkit", name: "Dev kit"),
    ]

    @Test func loginsStartingWithWhatsTypedComeFirstThenNamesThenTheRestEachInTheOrderGiven() {
        #expect(Mentions.matches(people, for: "van").map(\.login) == ["vanessa", "kit-vance"])
        #expect(Mentions.matches(people, for: "KIT").map(\.login) == ["kit-vance", "vanessa", "acme/devkit"], "ignoring case")
        #expect(Mentions.matches(people, for: "court").map(\.login) == ["eharcourt"])
        #expect(Mentions.matches(people, for: "").map(\.login) == people.map(\.login), "everyone, before anything's typed")
        #expect(Mentions.matches(people, for: "", limit: 2).count == 2)
        #expect(Mentions.matches(people, for: "zz").isEmpty)
    }
}
