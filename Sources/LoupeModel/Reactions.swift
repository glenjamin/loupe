import Foundation

/// One of the eight reactions GitHub offers, in the order its picker lists them.
public enum Reaction: String, Sendable, CaseIterable, Identifiable {
    case thumbsUp = "THUMBS_UP"
    case thumbsDown = "THUMBS_DOWN"
    case laugh = "LAUGH"
    case hooray = "HOORAY"
    case confused = "CONFUSED"
    case heart = "HEART"
    case rocket = "ROCKET"
    case eyes = "EYES"

    public var id: String { rawValue }

    public var emoji: String {
        switch self {
        case .thumbsUp: "👍"
        case .thumbsDown: "👎"
        case .laugh: "😄"
        case .hooray: "🎉"
        case .confused: "😕"
        case .heart: "❤️"
        case .rocket: "🚀"
        case .eyes: "👀"
        }
    }

    /// GitHub's name for it, as its picker's tooltips give.
    public var name: String {
        switch self {
        case .thumbsUp: "+1"
        case .thumbsDown: "-1"
        case .laugh: "laugh"
        case .hooray: "hooray"
        case .confused: "confused"
        case .heart: "heart"
        case .rocket: "rocket"
        case .eyes: "eyes"
        }
    }
}

/// Everyone who reacted to something with one reaction.
public struct ReactionGroup: Sendable, Equatable {
    public var content: Reaction
    public var count: Int
    public var viewerHasReacted: Bool

    public init(content: Reaction, count: Int, viewerHasReacted: Bool) {
        self.content = content
        self.count = count
        self.viewerHasReacted = viewerHasReacted
    }
}

extension [ReactionGroup] {
    /// The groups anyone has reacted with, in GitHub's order, as they're shown.
    public init(shown groups: some Sequence<ReactionGroup>) {
        let byContent = Dictionary(groups.map { ($0.content, $0) }, uniquingKeysWith: { first, _ in first })
        self = Reaction.allCases.compactMap { byContent[$0] }.filter { $0.count > 0 }
    }

    /// The groups with the viewer's `content` reaction added, or taken away.
    public func setting(_ content: Reaction, reacted: Bool) -> [ReactionGroup] {
        var groups = self
        if let index = groups.firstIndex(where: { $0.content == content }) {
            guard groups[index].viewerHasReacted != reacted else { return self }
            groups[index].viewerHasReacted = reacted
            groups[index].count = Swift.max(0, groups[index].count + (reacted ? 1 : -1))
        } else if reacted {
            groups.append(ReactionGroup(content: content, count: 1, viewerHasReacted: true))
        }
        return [ReactionGroup](shown: groups)
    }

    /// Whether the viewer has reacted with `content`.
    public func viewerHasReacted(_ content: Reaction) -> Bool {
        contains { $0.content == content && $0.viewerHasReacted }
    }
}

extension Conversation {
    /// The reactions to the description, a comment, a review or a thread comment, by its id;
    /// nil for an id that's none of them.
    public func reactions(to subjectId: String) -> [ReactionGroup]? {
        if subjectId == id { return reactions }
        if let item = items.first(where: { $0.id == subjectId }) { return item.reactions }
        for thread in threads {
            if let comment = thread.comments.first(where: { $0.id == subjectId }) { return comment.reactions }
        }
        return nil
    }

    /// Gives whatever has `subjectId` the reactions `groups`.
    public mutating func setReactions(_ groups: [ReactionGroup], of subjectId: String) {
        if subjectId == id { reactions = groups }
        for index in items.indices where items[index].id == subjectId {
            items[index].reactions = groups
        }
        for index in threads.indices {
            threads[index].setReactions(groups, of: subjectId)
        }
    }
}

extension ReviewThread {
    /// Gives the thread's comment with `commentId` the reactions `groups`, if it has it.
    public mutating func setReactions(_ groups: [ReactionGroup], of commentId: String) {
        for index in comments.indices where comments[index].id == commentId {
            comments[index].reactions = groups
        }
    }
}
