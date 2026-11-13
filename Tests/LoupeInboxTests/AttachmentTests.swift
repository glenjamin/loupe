@testable import LoupeFakeGitHub
import Foundation
import LoupeInbox
import Testing

/// Videos uploaded to GitHub play from short-lived signed addresses, as their own need the
/// viewer's GitHub sign-in, which the app's pages haven't.
@MainActor
struct AttachmentTests {
    @Test func anUploadedVideoIsSignedAfreshEachTimeAndNothingElseIsAskedAbout() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.mine[0]
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        let video = try #require(URL(string: "https://github.com/user-attachments/assets/\(FakeAttachments.video)"))

        let signed = try #require(await tab.signedAttachmentURL(video))
        #expect(signed.host() == "attachments.example")
        let again = await tab.signedAttachmentURL(video)
        #expect(again != nil && again != signed, "a fresh one, as the last may have expired")

        #expect(await tab.signedAttachmentURL(try #require(URL(string: "https://github.com/user-attachments/assets/no-such-thing"))) == nil)
        for elsewhere in ["https://example.com/user-attachments/assets/\(FakeAttachments.video)", "http://github.com/user-attachments/assets/\(FakeAttachments.video)", "https://github.com/settings/tokens"] {
            #expect(await tab.signedAttachmentURL(try #require(URL(string: elsewhere))) == nil, "the token goes nowhere else: \(elsewhere)")
        }
    }
}
