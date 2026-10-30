@testable import LoupeFakeGitHub
import LoupeInbox
import LoupeModel
import Testing

/// The emoji a comment box completes, fetched from GitHub's list once a run.
@MainActor
struct EmojiCatalogTests {
    @Test func gitHubsListGivesEachNameItsCharacterAndItsOwnEmojiNone() async throws {
        let (app, tab, _) = try await ThreadsApp.withThread()
        defer { withExtendedLifetime(app) {} }
        #expect(tab.emojis.isEmpty, "until fetched")
        await tab.fetchEmojis()

        let byName = Dictionary(uniqueKeysWithValues: tab.emojis.map { ($0.name, $0.character) })
        #expect(byName["tada"] == "🎉")
        #expect(byName["afghanistan"] == "🇦🇫", "a flag, from two code points")
        #expect(byName["copyright"] == "\u{a9}\u{fe0f}", "as an emoji, not text")
        #expect(byName["hash"] == "#\u{fe0f}\u{20e3}", "a keycap")
        #expect(byName["shipit"] == .some(nil), "GitHub's own, an image alone")
        #expect(tab.emojis.count == 20)
    }
}
