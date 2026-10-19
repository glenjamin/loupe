import Foundation
import LoupeModel

extension GitHubClient {
    /// Each PR in `ids` as it is now, with the PRs around it in its stack, as list rows: every
    /// member of its GitHub stack, merged ones included, and the open PR whose head is its base
    /// branch. Each is given once. PRs GitHub no longer has (or no longer shows the user) are
    /// left out.
    public func stackNeighbours(of ids: [String]) async throws -> [PullRequestSummary] {
        var found: [PullRequestSummary] = []
        for start in stride(from: 0, to: ids.count, by: Self.stackPageSize) {
            let batch = Array(ids[start..<min(start + Self.stackPageSize, ids.count)])
            let response: StackNodesResponse = try await query(Self.stackNeighboursQuery, variables: NodesVariables(ids: batch), allowingMissingNodes: true)
            for case let node? in response.nodes {
                let members = node.stack?.entries.nodes.compactMap(\.pullRequest) ?? []
                let parent = node.baseRef?.associatedPullRequests.nodes ?? []
                for row in [node.row] + members + parent where !found.contains(where: { $0.id == row.id }) {
                    found.append(PullRequestSummary(row))
                }
            }
        }
        return found
    }

    /// Each PR asks for up to a stack's worth of full rows, so fewer go in a request than in the
    /// other lookups by id.
    static let stackPageSize = 20

    static let stackNeighboursQuery = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            ...PullRequestRow
            ... on PullRequest {
              stack { entries(first: 50) { nodes { pullRequest { ...PullRequestRow } } } }
              baseRef { associatedPullRequests(states: OPEN, first: 1) { nodes { ...PullRequestRow } } }
            }
          }
        }
        """ + pullRequestRowFragment
}

private struct StackNodesResponse: Decodable {
    /// Null where an id couldn't be resolved.
    let nodes: [Node?]

    /// The PR's own row, and the rows around it.
    struct Node: Decodable {
        let row: SearchPageResponse.PullRequestNode
        let stack: Stack?
        let baseRef: BaseRef?

        init(from decoder: any Decoder) throws {
            row = try SearchPageResponse.PullRequestNode(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            stack = try container.decodeIfPresent(Stack.self, forKey: .stack)
            baseRef = try container.decodeIfPresent(BaseRef.self, forKey: .baseRef)
        }

        enum CodingKeys: String, CodingKey {
            case stack, baseRef
        }
    }

    struct Stack: Decodable {
        let entries: SearchPageResponse.Connection<Entry>
    }

    struct Entry: Decodable {
        /// Null where the viewer can't see it.
        let pullRequest: SearchPageResponse.PullRequestNode?
    }

    struct BaseRef: Decodable {
        let associatedPullRequests: SearchPageResponse.Connection<SearchPageResponse.PullRequestNode>
    }
}
