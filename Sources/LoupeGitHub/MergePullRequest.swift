import Foundation

extension GitHubClient {
    /// Merges the PR with `pullRequestId` into its base with a merge commit, as long as its head
    /// is still `expectedHeadOid`: GitHub refuses rather than merge commits pushed since. The
    /// head branch is left for the repo's own setting to delete.
    public func mergePullRequest(id pullRequestId: String, expectedHeadOid: String) async throws {
        let input = MergePullRequestInput(pullRequestId: pullRequestId, mergeMethod: "MERGE", expectedHeadOid: expectedHeadOid)
        let _: MergePullRequestResponse = try await query(Self.mergePullRequestMutation, variables: MergePullRequestVariables(input: input))
    }

    static let mergePullRequestMutation = """
        mutation($input: MergePullRequestInput!) {
          mergePullRequest(input: $input) { pullRequest { id state } }
        }
        """
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
