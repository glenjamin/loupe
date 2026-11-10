import Foundation

extension GitHubClient {
    /// The PR's description as it is on GitHub now, in markdown: what editing it should start
    /// from, as it may have been edited on github.com since the conversation was fetched.
    public func pullRequestBody(id: String) async throws -> String {
        let response: BodyResponse = try await query(Self.pullRequestBodyQuery, variables: BodyVariables(id: id))
        guard let body = response.node?.body else { throw GitHubError.graphQL(["Pull request \(id) not found"]) }
        return body
    }

    /// Replaces the PR's description with `body`, in markdown.
    public func updatePullRequestBody(_ body: String, pullRequestId: String) async throws {
        try await updatePullRequest(UpdatePullRequestInput(pullRequestId: pullRequestId, body: body))
    }

    /// Renames the PR to `title`.
    public func updatePullRequestTitle(_ title: String, pullRequestId: String) async throws {
        try await updatePullRequest(UpdatePullRequestInput(pullRequestId: pullRequestId, title: title))
    }

    static let pullRequestBodyQuery = """
        query($id: ID!) {
          node(id: $id) { ... on PullRequest { body } }
        }
        """

    static let updatePullRequestMutation = """
        mutation($input: UpdatePullRequestInput!) {
          updatePullRequest(input: $input) { pullRequest { id } }
        }
        """

    private func updatePullRequest(_ input: UpdatePullRequestInput) async throws {
        let _: UpdatePullRequestResponse = try await query(Self.updatePullRequestMutation, variables: UpdatePullRequestVariables(input: input))
    }
}

private struct BodyVariables: Encodable, Sendable {
    let id: String
}

private struct BodyResponse: Decodable {
    let node: Node?

    struct Node: Decodable {
        let body: String
    }
}

private struct UpdatePullRequestVariables: Encodable, Sendable {
    let input: UpdatePullRequestInput
}

private struct UpdatePullRequestInput: Encodable, Sendable {
    let pullRequestId: String
    /// Left out when nil, so only what's given changes.
    var title: String?
    var body: String?
}

private struct UpdatePullRequestResponse: Decodable {}
