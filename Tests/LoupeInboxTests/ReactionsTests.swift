@testable import LoupeFakeGitHub
import Foundation
import LoupeCore
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ReactionsTests {
    @Test func reactionsComeWithTheConversationAndAreStored() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        try await app.conversations.react("HEART", to: pullRequest.id, by: FakeGitHub.viewer)
        try await app.conversations.react("HEART", to: pullRequest.id)
        try await app.conversations.react("ROCKET", to: pullRequest.id)
        try await app.conversations.react("LAUGH", to: firstComment)

        let tab = try await app.open(pullRequest)

        let conversation = try #require(tab.conversation)
        #expect(conversation.reactions == [
            ReactionGroup(content: .heart, count: 2, viewerHasReacted: true),
            ReactionGroup(content: .rocket, count: 1, viewerHasReacted: false),
        ], "the description's, those no one made left out, in GitHub's order")
        #expect(conversation.reactions(to: firstComment) == [ReactionGroup(content: .laugh, count: 1, viewerHasReacted: false)])
        #expect(conversation.reactions(to: thumbedUpComment) == [ReactionGroup(content: .thumbsUp, count: 1, viewerHasReacted: false)], "as captured on atrium#2928")
        #expect(conversation.reactions(to: firstReview) == [])
        #expect(try app.store.conversation(of: pullRequest.id) == conversation)
    }

    @Test func aReactionShowsAtOnceAndIsSentToGitHub() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        let tab = try await app.open(pullRequest)
        await app.conversations.holdReactions()

        let reacting = Task { await tab.react(ReactionLink(.add, .thumbsUp, on: thumbedUpComment)) }
        try await until { tab.conversation?.reactions(to: thumbedUpComment)?.first?.viewerHasReacted == true }

        let shown = [ReactionGroup(content: .thumbsUp, count: 2, viewerHasReacted: true)]
        #expect(tab.conversation?.reactions(to: thumbedUpComment) == shown, "before GitHub answers")
        try await untilReceived(1, by: app)
        #expect(try app.store.conversation(of: pullRequest.id)?.reactions(to: thumbedUpComment) == shown)
        await app.conversations.releaseReactions()
        await reacting.value

        #expect(await app.conversations.reactionsReceived == [.init(subjectId: thumbedUpComment, content: "THUMBS_UP", added: true)])
        #expect(tab.conversation?.reactions(to: thumbedUpComment) == shown)
        await tab.reload()
        #expect(tab.conversation?.reactions(to: thumbedUpComment) == shown, "as GitHub has it")
    }

    @Test func removingAReactionTakesTheViewersAway() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        try await app.conversations.react("EYES", to: pullRequest.id, by: FakeGitHub.viewer)
        try await app.conversations.react("EYES", to: pullRequest.id)
        try await app.conversations.react("HOORAY", to: pullRequest.id, by: FakeGitHub.viewer)
        let tab = try await app.open(pullRequest)

        await tab.react(ReactionLink(.remove, .eyes, on: pullRequest.id))
        await tab.react(ReactionLink(.remove, .hooray, on: pullRequest.id))

        let left = [ReactionGroup(content: .eyes, count: 1, viewerHasReacted: false)]
        #expect(tab.conversation?.reactions == left, "someone else's 👀 stays; the 🎉 no one else made goes")
        #expect(try app.store.conversation(of: pullRequest.id)?.reactions == left)
        await tab.reload()
        #expect(tab.conversation?.reactions == left)
    }

    @Test func askingForWhatsAlreadySoSendsNothing() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        let tab = try await app.open(pullRequest)

        await tab.react(ReactionLink(.remove, .thumbsUp, on: thumbedUpComment))
        await tab.react(ReactionLink(.add, .thumbsUp, on: "IC_not_in_this_conversation"))

        #expect(await app.conversations.reactionsReceived.isEmpty)
        #expect(tab.conversation?.reactions(to: thumbedUpComment) == [ReactionGroup(content: .thumbsUp, count: 1, viewerHasReacted: false)])
    }

    @Test func aRefusedReactionIsPutBack() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        let tab = try await app.open(pullRequest)
        await app.conversations.refuseReactions()

        await tab.react(ReactionLink(.add, .heart, on: firstComment))

        #expect(await app.conversations.reactionsReceived.count == 1)
        #expect(tab.conversation?.reactions(to: firstComment) == [])
        #expect(try app.store.conversation(of: pullRequest.id)?.reactions(to: firstComment) == [])
    }
}

@MainActor
struct ThreadReactionsTests {
    @Test func aThreadCommentsReactionShowsOnTheDiffAndSurvivesFetchingTheThreadsAgain() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        let commentId = try #require(tab.thread(threadId)?.comments.first?.id)

        await tab.react(ReactionLink(.add, .rocket, on: commentId))

        let shown = [ReactionGroup(content: .rocket, count: 1, viewerHasReacted: true)]
        #expect(tab.thread(threadId)?.comments.first?.reactions == shown)
        #expect(tab.placedThreads.first { $0.id == threadId }?.comments.first?.reactions == shown, "on the diff too")
        await tab.follow(ThreadLink(.resolve, thread: threadId))
        #expect(tab.thread(threadId)?.comments.first?.reactions == shown, "fetched again with the threads")
        #expect(try app.store.conversation(of: tab.id)?.threads == tab.conversation?.threads)
    }

    @Test func aRefusedReactionOnAThreadCommentIsPutBackAndSaysWhyOnTheThread() async throws {
        let (app, tab, threadId) = try await ThreadsApp.withThread()
        let commentId = try #require(tab.thread(threadId)?.comments.first?.id)
        await app.conversations.refuseReactions()

        await tab.react(ReactionLink(.add, .rocket, on: commentId))

        #expect(tab.thread(threadId)?.comments.first?.reactions == [])
        #expect(tab.placedThreads.first { $0.id == threadId }?.comments.first?.reactions == [])
        #expect(tab.threadActivity.errors[threadId]?.contains("Couldn't react with 🚀") == true)
    }
}

/// Comments in `probe/conversation.json`: the first in the timeline, and a thread comment with a 👍.
private let firstComment = "IC_kwDODst66c8AAAABbfarpg"
private let firstReview = "PRR_kwDODst66c8AAAABSCogpw"
private let thumbedUpComment = "PRRC_kwDODst66c798GMC"

private extension ConversationApp {
    /// The PR open in its tab, its conversation fetched.
    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }
}

/// Waits for GitHub to have been sent `count` reactions.
@MainActor
private func untilReceived(_ count: Int, by app: ConversationApp) async throws {
    try await until { await app.conversations.reactionsReceived.count >= count }
}
