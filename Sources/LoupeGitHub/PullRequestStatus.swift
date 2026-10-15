import Foundation
import LoupeModel

extension GitHubClient {
    /// The head commit's checks, whether it merges cleanly, whether it can be merged now and its
    /// review decision, for each PR in `ids`, keyed by id,
    /// looked up by id in batches small enough to stay well inside GitHub's time limit. PRs
    /// GitHub no longer has (or no longer shows the user) are left out.
    public func statuses(ofPullRequests ids: [String]) async throws -> [String: PullRequestStatus] {
        var statuses: [String: PullRequestStatus] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.statusBatchSize) {
            let batch = Array(ids[start..<min(start + Self.statusBatchSize, ids.count)])
            let response: StatusResponse = try await query(Self.statusQuery, variables: NodesVariables(ids: batch), allowingMissingNodes: true)
            for case let node? in response.nodes {
                let rollup = node.commits.nodes.first?.commit.statusCheckRollup
                statuses[node.id] = PullRequestStatus(
                    checks: rollup?.state,
                    checkContexts: rollup?.contexts.nodes.compactMap(\.check) ?? [],
                    mergeable: node.mergeable,
                    mergeStateStatus: node.mergeStateStatus,
                    reviewDecision: node.reviewDecision
                )
            }
        }
        return statuses
    }

    /// Under GitHub's maximum, as contexts and mergeability make each PR costly to look up.
    static let statusBatchSize = 50

    static let statusQuery = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on PullRequest {
              id
              mergeable
              mergeStateStatus
              reviewDecision
              commits(last: 1) {
                nodes { commit { statusCheckRollup { state contexts(first: 50) { nodes { \(checkContextFields) } } } } }
              }
            }
          }
        }
        """

    /// A check run's title is where e.g. Codecov puts its coverage summary.
    static let checkContextFields = """
        __typename
        ... on CheckRun { name status conclusion title detailsUrl }
        ... on StatusContext { context state description targetUrl }
        """
}

/// A `CheckRun` or a `StatusContext`, which name the same things differently.
struct CheckContextNode: Decodable {
    let __typename: String
    let name: String?
    let status: String?
    let conclusion: String?
    let title: String?
    let detailsUrl: String?
    let context: String?
    let state: String?
    let description: String?
    let targetUrl: String?

    var check: CheckContext? {
        switch __typename {
        case "CheckRun":
            guard let name else { return nil }
            return CheckContext(name: name, status: checkRunStatus(status: status, conclusion: conclusion), description: title, url: detailsUrl)
        case "StatusContext":
            guard let context else { return nil }
            return CheckContext(name: context, status: statusContextStatus(state), description: description, url: targetUrl)
        default:
            return nil
        }
    }
}

private struct StatusResponse: Decodable {
    /// Null where an id couldn't be resolved.
    let nodes: [Node?]

    struct Node: Decodable {
        let id: String
        let mergeable: MergeableState
        let mergeStateStatus: MergeStateStatus
        let reviewDecision: ReviewDecision?
        let commits: SearchPageResponse.Connection<CommitNode>
    }

    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }

    struct Rollup: Decodable {
        let state: CheckState
        let contexts: SearchPageResponse.Connection<CheckContextNode>
    }
}

private func checkRunStatus(status: String?, conclusion: String?) -> CheckStatus {
    guard status == "COMPLETED" else { return .pending }
    switch conclusion {
    case "SUCCESS": return .success
    case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failure
    default: return .neutral
    }
}

private func statusContextStatus(_ state: String?) -> CheckStatus {
    switch state {
    case "SUCCESS": .success
    case "FAILURE", "ERROR": .failure
    default: .pending
    }
}
