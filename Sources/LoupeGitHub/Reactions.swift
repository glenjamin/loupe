import Foundation
import LoupeModel

extension GitHubClient {
    /// Adds the viewer's `content` reaction to the PR, comment, review or review comment with
    /// `subjectId`, or takes it away, returning its reactions as GitHub then has them.
    @discardableResult
    public func setReaction(_ content: Reaction, reacted: Bool, subjectId: String) async throws -> [ReactionGroup] {
        let variables = ReactionVariables(subjectId: subjectId, content: content.rawValue)
        if reacted {
            let response: AddReactionResponse = try await query(Self.addReactionMutation, variables: variables)
            return response.addReaction.subject.groups
        }
        let response: RemoveReactionResponse = try await query(Self.removeReactionMutation, variables: variables)
        return response.removeReaction.subject.groups
    }

    /// Asked for on everything in a conversation that can be reacted to.
    static let reactionGroupsField = "reactionGroups { content viewerHasReacted reactors { totalCount } }"

    static let addReactionMutation = """
        mutation($subjectId: ID!, $content: ReactionContent!) {
          addReaction(input: { subjectId: $subjectId, content: $content }) { subject { \(reactionGroupsField) } }
        }
        """

    static let removeReactionMutation = """
        mutation($subjectId: ID!, $content: ReactionContent!) {
          removeReaction(input: { subjectId: $subjectId, content: $content }) { subject { \(reactionGroupsField) } }
        }
        """
}

/// One group as `reactionGroupsField` returns it.
struct ReactionGroupNode: Decodable {
    let content: String
    let viewerHasReacted: Bool
    let reactors: Count

    struct Count: Decodable { let totalCount: Int }

    /// Nil for a reaction GitHub has added since.
    var group: ReactionGroup? {
        Reaction(rawValue: content).map { ReactionGroup(content: $0, count: reactors.totalCount, viewerHasReacted: viewerHasReacted) }
    }
}

extension Optional<[ReactionGroupNode]> {
    /// The groups anyone has reacted with; none where they weren't asked for, as in captures
    /// made before they were.
    var shown: [ReactionGroup] {
        [ReactionGroup](shown: (self ?? []).compactMap(\.group))
    }
}

private struct ReactionVariables: Encodable, Sendable {
    let subjectId: String
    let content: String
}

private struct ReactableNode: Decodable {
    let reactionGroups: [ReactionGroupNode]?

    var groups: [ReactionGroup] { reactionGroups.shown }
}

private struct AddReactionResponse: Decodable {
    let addReaction: Payload

    struct Payload: Decodable { let subject: ReactableNode }
}

private struct RemoveReactionResponse: Decodable {
    let removeReaction: Payload

    struct Payload: Decodable { let subject: ReactableNode }
}
