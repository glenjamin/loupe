import Foundation

extension GitHubClient {
    /// Merges the PR with `pullRequestId` into its base with a merge commit, as long as its head
    /// is still `expectedHeadOid`: GitHub refuses rather than merge commits pushed since. The
    /// head branch is left for the repo's own setting to delete. GitHub refuses this for a PR in
    /// one of its stacks, which `requestAsyncMerge` merges.
    public func mergePullRequest(id pullRequestId: String, expectedHeadOid: String) async throws {
        let input = MergePullRequestInput(pullRequestId: pullRequestId, mergeMethod: "MERGE", expectedHeadOid: expectedHeadOid)
        let _: MergePullRequestResponse = try await query(Self.mergePullRequestMutation, variables: MergePullRequestVariables(input: input))
    }

    /// Asks GitHub to merge PR `number` in `repository` (`owner/name`) with a merge commit in the
    /// background, through its asynchronous merge endpoint, which a PR in a GitHub stack must be
    /// merged with. That merges every open PR below this one in its stack too. GitHub cancels the
    /// merge if the head is no longer `expectedHeadOid` when it runs. Where a merge of the PR is
    /// already under way, GitHub answers with that one, to follow instead.
    public func requestAsyncMerge(repository: String, number: Int, expectedHeadOid: String) async throws -> AsyncMergeResult {
        let request = AsyncMergeRequest(sha: expectedHeadOid, merge_method: "merge", merge_action: "direct_merge")
        let body = try await rest("PUT", path: "/repos/\(repository)/pulls/\(number)/merge-async", json: JSONEncoder().encode(request), alsoAccepting: [409])
        return try AsyncMergeResult(body)
    }

    /// Where the background merge GitHub named `uuid` has got to.
    public func asyncMergeResult(repository: String, number: Int, uuid: String) async throws -> AsyncMergeResult {
        try AsyncMergeResult(try await rest("GET", path: "/repos/\(repository)/pulls/\(number)/merge-async/\(uuid)"))
    }

    static let mergePullRequestMutation = """
        mutation($input: MergePullRequestInput!) {
          mergePullRequest(input: $input) { pullRequest { id state } }
        }
        """
}

/// Where a background merge has got to, as GitHub's asynchronous merge endpoint says.
public enum AsyncMergeResult: Sendable, Equatable {
    /// Still running; `uuid` names it, to ask after it again.
    case pending(uuid: String)
    case merged
    /// Added to the base branch's merge queue, which merges it later.
    case enqueued
    /// GitHub couldn't merge it, saying why.
    case failed(message: String)

    init(_ body: Data) throws {
        let response = try JSONDecoder().decode(AsyncMergeResponse.self, from: body)
        switch (response.status, response.details.uuid) {
        case let ("pending", uuid?): self = .pending(uuid: uuid)
        case ("merged", _): self = .merged
        case ("enqueued", _): self = .enqueued
        case ("failed", _): self = .failed(message: response.details.message ?? "GitHub couldn't merge it")
        default: self = .failed(message: "GitHub answered the merge with \(response.status)")
        }
    }
}

private struct MergePullRequestVariables: Encodable, Sendable {
    let input: MergePullRequestInput
}

private struct MergePullRequestInput: Encodable, Sendable {
    let pullRequestId: String
    let mergeMethod: String
    let expectedHeadOid: String
}

private struct MergePullRequestResponse: Decodable {}

/// The body GitHub's asynchronous merge takes, in its own names.
private struct AsyncMergeRequest: Encodable {
    let sha: String
    let merge_method: String
    /// Merged now rather than through a merge queue, as `mergePullRequest` does.
    let merge_action: String
}

private struct AsyncMergeResponse: Decodable {
    let status: String
    let details: Details

    /// One of several shapes by status: each has a message, a pending one its uuid.
    struct Details: Decodable {
        let message: String?
        let uuid: String?
    }
}
