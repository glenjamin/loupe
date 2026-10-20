import CryptoKit
import Foundation
import LoupeInbox
import LoupeModel
import Testing

/// Following links to a part of a PR, from another app or inside Loupe: each lands on what it
/// points at.
@MainActor
struct LinkLandingTests {
    @Test func aLinkToACommentOrReviewShowsTheConversationLandedOnIt() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let tab = try await app.open(pullRequest)
        tab.section = .files

        await app.tabs.open(try deepLink(to: pullRequest, "#issuecomment-\(probeComment.databaseId)"))?.value
        #expect(app.tabs.selected == tab.id)
        #expect(tab.section == .conversation)
        let landing = try #require(tab.conversationLanding)
        #expect(landing.ids == [probeComment.id])

        tab.didLand(landing)
        #expect(tab.conversationLanding == nil, "landed once")

        tab.section = .files
        await app.tabs.open(try deepLink(to: pullRequest, "#pullrequestreview-\(probeReview.databaseId)"))?.value
        #expect(tab.section == .conversation)
        #expect(tab.conversationLanding?.ids == [probeReview.id])

        // A review's id isn't a comment's, though GitHub numbers them alike.
        await app.tabs.open(try deepLink(to: pullRequest, "#issuecomment-\(probeReview.databaseId)"))?.value
        #expect(tab.section == .conversation)
        #expect(tab.conversationLanding == nil, "nothing to land on, so the conversation is shown as it is")
    }

    @Test func aCommentNewerThanTheStoredConversationIsLandedOnOnceFetched() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let tab = try await app.open(pullRequest)
        let pagesServed = await app.conversations.pagesServed
        let commentId = await app.conversations.comment("<p>Just now</p>", on: pullRequest.id)
        let databaseId = try #require(await app.conversations.databaseId(of: commentId, on: pullRequest.id))

        await app.tabs.open(try deepLink(to: pullRequest, "#issuecomment-\(databaseId)"))?.value

        #expect(await app.conversations.pagesServed == pagesServed + 1, "fetched again, as it wasn't stored")
        #expect(tab.conversationLanding?.ids == [commentId])
        await app.tabs.open(try deepLink(to: pullRequest, "#issuecomment-\(databaseId)"))?.value
        #expect(await app.conversations.pagesServed == pagesServed + 1, "stored now, so not fetched again")
    }

    @Test func storedCommentsKeepTheirIdsSoTheNextRunLandsWithoutAskingGitHub() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        _ = try await app.open(pullRequest)
        let nextRun = app.relaunch()
        let pagesServed = await app.conversations.pagesServed

        await nextRun.open(try deepLink(to: pullRequest, "#pullrequestreview-\(probeReview.databaseId)"))?.value

        #expect(nextRun.tab(id: pullRequest.id)?.conversationLanding?.ids == [probeReview.id])
        #expect(await app.conversations.pagesServed == pagesServed)
    }

    @Test func aLinkToAPullRequestNotYetShownWaitsForItsConversation() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        await app.conversations.hold(.conversation)

        let opening = try #require(app.tabs.open(try deepLink(to: pullRequest, "#issuecomment-\(probeComment.databaseId)")))
        await app.conversations.arrival(of: .conversation)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        #expect(app.tabs.selected == tab.id)
        #expect(tab.section == .conversation)
        #expect(tab.conversationLanding == nil, "not until the conversation has come")

        await app.conversations.release(.conversation)
        await opening.value
        #expect(tab.conversationLanding?.ids == [probeComment.id])
    }

    @Test func movingToTheFilesWhileTheConversationIsFetchedDropsTheLanding() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        await app.conversations.hold(.conversation)

        let opening = try #require(app.tabs.open(try deepLink(to: pullRequest, "#issuecomment-\(probeComment.databaseId)")))
        await app.conversations.arrival(of: .conversation)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        tab.section = .files
        await app.conversations.release(.conversation)
        await opening.value

        #expect(tab.section == .files, "the viewer's choice stands")
        #expect(tab.conversationLanding == nil)
    }

    @Test func aLinkToAThreadsCommentShowsItOnItsLineInTheWholePullRequestsDiff() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        let commit = try #require(tab.ready?.commits.last)
        await tab.show(.commit(commit.oid))
        tab.selectedFile = "new.go"
        tab.section = .conversation
        let databaseId = try #require(tab.thread(threadId)?.comments.first?.databaseId)

        for anchor in ["/files#r\(databaseId)", "#discussion_r\(databaseId)", "/changes#r\(databaseId)"] {
            tab.section = .conversation
            tab.threadActivity.didReveal(threadId)
            await app.tabs.open(try deepLink(to: tab.pullRequest, anchor))?.value

            #expect(tab.section == .files, "\(anchor)")
            #expect(tab.shownChoice == .all, "threads are placed on the whole PR's diff")
            #expect(tab.selectedFile == "app.go")
            #expect(tab.threadActivity.revealing == threadId, "for the diff to scroll to once drawn")
            #expect(tab.threadActivity.highlighted == threadId, "marked for a moment")
            #expect(tab.conversationLanding == nil)
        }
    }

    @Test func aLinkToAThreadTheDiffHasNoLineForLandsOnItInTheConversation() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let outdated = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 3, outdated: true, body: "Gone now")
        let unshownLine = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: 30, body: "And here?")
        let onFile = try await app.conversations.startThread(on: pullRequest.id, path: "app.go", line: nil, body: "This whole file")
        let gone = try await app.conversations.startThread(on: pullRequest.id, path: "removed.go", line: 4, body: "Still needed?")
        let tab = try await app.open(pullRequest)

        for threadId in [outdated, unshownLine, onFile, gone] {
            tab.section = .files
            let thread = try #require(tab.thread(threadId))
            let comment = try #require(thread.comments.first)
            let databaseId = try #require(comment.databaseId)

            await app.tabs.open(try deepLink(to: pullRequest, "/files#r\(databaseId)"))?.value

            #expect(tab.section == .conversation, "\(thread.path):\(thread.line ?? 0)")
            #expect(tab.conversationLanding?.ids == [comment.id, threadId], "its comment, or the thread if the page hasn't that")
            #expect(tab.threadActivity.revealing == nil)
            #expect(tab.threadActivity.unshown == nil, "landed on rather than said it can't be shown")
        }
    }

    @Test func aLinkToAThreadOnAHiddenFilesLineShowsItInThatFilesDiff() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let vendored = try await app.conversations.startThread(on: pullRequest.id, path: "vendor/example.com/lib/lib.go", line: 1, body: "Vendored?")
        let tab = try await app.open(pullRequest)
        let databaseId = try #require(tab.thread(vendored)?.comments.first?.databaseId)

        await app.tabs.open(try deepLink(to: pullRequest, "#discussion_r\(databaseId)"))?.value

        #expect(tab.section == .files)
        #expect(tab.selectedFile == "vendor/example.com/lib/lib.go")
        #expect(tab.threadActivity.revealing == vendored)
    }

    @Test func aLinkToTheFilesShowsTheCommitAndFileItNames() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest()
        let tab = try await app.open(pullRequest)
        let commits = try #require(tab.ready?.commits)
        let changingApp = try #require(commits.first)

        await app.tabs.open(try deepLink(to: pullRequest, "/commits/\(changingApp.oid)#diff-\(anchor(of: "app.go"))"))?.value
        #expect(tab.section == .files)
        #expect(tab.shownChoice == .commit(changingApp.oid), "picked in the commit picker")
        #expect(tab.selectedFile == "app.go")

        tab.section = .conversation
        let addingNew = try #require(commits.last)
        await app.tabs.open(try deepLink(to: pullRequest, "/files/\(addingNew.oid.prefix(7))"))?.value
        #expect(tab.section == .files)
        #expect(tab.shownChoice == .commit(addingNew.oid), "by a prefix of its oid")
        #expect(tab.selectedFile == "new.go", "the commit's only file")

        await app.tabs.open(try deepLink(to: pullRequest, "/files#diff-\(anchor(of: "vendor/example.com/lib/lib.go"))"))?.value
        #expect(tab.shownChoice == .all, "the whole PR's files")
        #expect(tab.selectedFile == "vendor/example.com/lib/lib.go", "hidden files too")

        await app.tabs.open(try deepLink(to: pullRequest, "/commits/0000000#diff-\(anchor(of: "nowhere.go"))"))?.value
        #expect(tab.shownChoice == .all, "a commit that isn't the PR's shows all its changes")
        #expect(tab.selectedFile == "vendor/example.com/lib/lib.go", "and a file it hasn't leaves the file shown")
    }

    @Test func aLinkFromAnotherAppToAnUnstoredPullRequestLandsOnceItsTabIsFound() async throws {
        let app = try await ThreadsApp()
        try await app.conversations.add(porterId)
        let links = IncomingLinks(bringForward: {}, openInBrowser: { _ in })
        await links.ready(app.tabs)
        await app.github.hold(.numberLookup)

        let routed = try #require(URL(string: "loupe:///tamarinworks/porter/pull/1522#issuecomment-\(probeComment.databaseId)"))
        let opening = Task { await links.open([routed]) }
        await app.github.arrival(of: .numberLookup)
        let pending = try #require(app.tabs.items.last?.pending)
        #expect(app.tabs.selected == pending.id)

        // A second link to it while it's looked up says where to land instead.
        let review = try #require(URL(string: "https://github.com/tamarinworks/porter/pull/1522#pullrequestreview-\(probeReview.databaseId)"))
        let second = Task { await links.open([review]) }
        await app.github.release(.numberLookup)
        await opening.value
        await second.value

        let tab = try #require(app.tabs.tab(id: porterId))
        #expect(app.tabs.selected == tab.id)
        #expect(tab.section == .conversation)
        #expect(tab.conversationLanding?.ids == [probeReview.id])
    }
}

/// An issue comment and a review in `probe/conversation.json`, by node id and REST id.
private let probeComment = (id: "IC_kwDODst66c8AAAABbfarpg", databaseId: 6_139_849_638)
private let probeReview = (id: "PRR_kwDODst66c8AAAABSCogpw", databaseId: 5_505_687_719)
/// porter #1522's node id, from `probe/pr-by-number.json`.
private let porterId = "PR_kwDOCONLKc8AAAABIpeTvA"

/// A link to the PR on github.com with `suffix` naming a part of it.
private func deepLink(to pullRequest: PullRequestSummary, _ suffix: String) throws -> PullRequestLink {
    let url = try #require(URL(string: pullRequest.url.absoluteString + suffix))
    return try #require(PullRequestLink(url: url))
}

/// GitHub's `#diff-` anchor for a file: the SHA-256 of its path in hex.
private func anchor(of path: String) -> String {
    SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
}
