import Foundation

extension GitHubClient {
    /// Takes the PR with `pullRequestId` out of draft, as github.com's "Ready for review" does.
    public func markReadyForReview(id pullRequestId: String) async throws {
        let input = MarkReadyForReviewInput(pullRequestId: pullRequestId)
        let _: MarkReadyForReviewResponse = try await query(Self.markReadyForReviewMutation, variables: MarkReadyForReviewVariables(input: input))
    }

    static let markReadyForReviewMutation = """
        mutation($input: MarkPullRequestReadyForReviewInput!) {
          markPullRequestReadyForReview(input: $input) { pullRequest { id isDraft } }
        }
        """
}

private struct MarkReadyForReviewVariables: Encodable, Sendable {
    let input: MarkReadyForReviewInput
}

private struct MarkReadyForReviewInput: Encodable, Sendable {
    let pullRequestId: String
}

private struct MarkReadyForReviewResponse: Decodable {}
