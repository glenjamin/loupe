import Foundation
import LoupeCore
import LoupeModel

extension PullRequestTab {
    /// Adds the viewer's reaction, or takes it away, as a link from the conversation page or a
    /// thread's reaction asks. It shows at once, wherever the thing reacted to is shown, and is
    /// put back if GitHub refuses it, saying so on a thread comment's thread. Asking for what's
    /// already so does nothing.
    public func react(_ link: ReactionLink) async {
        let reacted = link.action == .add
        guard let current = conversation?.reactions(to: link.subjectId), current.viewerHasReacted(link.content) != reacted else { return }
        let threadId = conversation?.threads.first { $0.comments.contains { $0.id == link.subjectId } }?.id
        if let threadId { threadActivity.errors[threadId] = nil }
        await showReactions(current.setting(link.content, reacted: reacted), of: link.subjectId)
        do {
            try await client.setReaction(link.content, reacted: reacted, subjectId: link.subjectId)
        } catch {
            let undone = (conversation?.reactions(to: link.subjectId) ?? current).setting(link.content, reacted: !reacted)
            await showReactions(undone, of: link.subjectId)
            let message = "Couldn't \(reacted ? "react with" : "remove") \(link.content.emoji): \(error.localizedDescription)"
            log("\(message) on \(title)")
            if let threadId { threadActivity.errors[threadId] = message }
        }
    }

    /// Gives the thing reacted to `groups` in the conversation, on the diff's threads and in
    /// the store.
    private func showReactions(_ groups: [ReactionGroup], of subjectId: String) async {
        conversation?.setReactions(groups, of: subjectId)
        for index in threadsOfShownDiff.indices {
            threadsOfShownDiff[index].setReactions(groups, of: subjectId)
        }
        do {
            try await store.replaceReactions(of: subjectId, in: id, with: groups)
        } catch {
            log("Couldn't store the reactions on \(title): \(error)")
        }
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
