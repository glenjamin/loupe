import Foundation
import LoupeGitHub

/// GitHub as the fixtures under `probe/` have it, in-process, for a snapshot run with
/// `LOUPE_FIXTURES` set: the lists, lookups and checks from `FakeGitHub`, each PR's conversation,
/// reviewers and edits from `FakeConversations`, viewed files, rendered markdown and emoji. PRs that a
/// fixture checkout holds (`FixtureCheckouts`) have that checkout's commits. Nothing goes over
/// the network: a request none of the fakes can answer throws a `FakeGitHubMismatch`, kept in
/// `FakeGitHubMismatch.recorded`.
public final class FixtureGitHub: HTTPTransport {
    /// The token the fakes take; any other is refused as GitHub refuses a bad one.
    public static let token = FakeGitHub.validToken

    private let fakes: Task<Fakes, any Error>

    /// With the fixture checkouts under `checkouts`, if built there.
    public init(checkouts: URL) {
        fakes = Task { try await Fakes(checkouts: checkouts) }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await fakes.value.send(request)
        } catch let unanswered as FakeGitHubMismatch {
            throw unanswered
        } catch {
            throw mismatch("couldn't answer", "couldn't answer \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "no URL"): \(error)")
        }
    }
}

/// The fakes, set up as one GitHub, sending each request to the one that answers it.
private struct Fakes: Sendable {
    let github: FakeGitHub
    let conversations = FakeConversations()
    let viewed = FakeViewedFiles()
    let markdown = FakeMarkdown()

    init(checkouts: URL) async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        let branches = try FixtureCheckouts.branches(in: checkouts)
        for pullRequest in await github.everyPullRequest {
            try await conversations.add(pullRequest.id, number: pullRequest.number, author: pullRequest.author?.login)
            guard let branch = branches.first(where: { $0.repository == pullRequest.repository.nameWithOwner && $0.number == pullRequest.number }) else { continue }
            let commits = branch.commits.map { FakePullRequest.HistoryCommit(oid: $0, committedDate: branch.committedAt) }
            try await github.setBranch(of: pullRequest.id, base: branch.base, commits: commits)
            if branch.conflicting { try await github.setMergeState(of: pullRequest.id, "DIRTY", mergeable: "CONFLICTING") }
            if let head = commits.last { await conversations.setHead(head.oid, of: pullRequest.id) }
        }
        for pullRequest in await github.everyPullRequest where pullRequest.state == "MERGED" {
            try await github.setMergeCommitChecks(of: pullRequest.id, state: "FAILURE", Self.brokenBaseBranch)
        }
    }

    /// The base branch's checks after a merge that broke it, the failed job one the CircleCI
    /// fixture has.
    static let brokenBaseBranch: [FakeCheckContext] = [
        .status("ci/circleci: build", "SUCCESS"),
        .status("ci/circleci: typecheck", "FAILURE", url: "https://app.circleci.com/workflow/38f76f1c-9800-7454-8f63-a838bc6fff99/job/c0555525-bd97-b6dd-530a-7ffc511c2525"),
        .status("ci/circleci: deploy", "PENDING"),
    ]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try require(request.url, "a request with no URL")
        try expect(url.host() == "api.github.com", "a request for \(url.absoluteString), which isn't GitHub's API")
        switch url.path() {
        case "/notifications": return try await github.send(request)
        case "/markdown": return try await markdown.send(request)
        case "/emojis": return try FakeEmojis().send(request)
        case let path where path.contains("/merge-async"): return try await github.send(request)
        case let path where path.hasPrefix("/repos/"): return try await conversations.sendREST(request)
        case "/graphql": break
        default: throw mismatch("unknown", "no fake answers \(request.httpMethod ?? "GET") \(url.path())")
        }
        let body = try require(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }, "a GraphQL request without a JSON body")
        let query = try require(body["query"] as? String, "a GraphQL request without a query")
        let variables = body["variables"] as? [String: Any] ?? [:]
        let isList = variables["ids"] != nil || variables["number"] != nil || query.contains("search(query:")
            || query.contains("mergePullRequest(") || query.contains("markPullRequestReadyForReview(") || query.contains("viewer { login }")
        if isList { return try await github.send(request) }
        if query.contains("viewerViewedState") || query.contains("FileAsViewed(") { return try await viewed.send(request) }
        return try await conversations.send(request)
    }
}
