import Foundation
import LoupeGitHub
import LoupeModel
import LoupeStore
import Observation

/// Who can be asked to review in each repo, fetched from GitHub once a run and shared by every
/// tab, so the request-a-review search filters them as the viewer types rather than asking
/// GitHub each time. A repo's people and teams rarely change while the app runs. They're
/// offered in `ReviewerRanking`'s order.
@Observable
@MainActor
final class ReviewerCandidates {
    /// Each repo's candidates once fetched, by lowercased `owner/name`.
    private var fetched: [String: [Reviewer]] = [:]
    /// When each reviewer was last asked in each repo, by lowercased `owner/name` then
    /// `Reviewer.id`. Read from the store once a run and kept up to date with each request.
    private var lastRequested: [String: [String: Date]] = [:]
    /// Fetches on their way, shared by everyone asking for the same repo meanwhile.
    @ObservationIgnored private var fetching: [String: Task<[Reviewer], any Error>] = [:]
    private let client: GitHubClient

    init(client: GitHubClient) {
        self.client = client
    }

    /// The candidates in `repository`, those asked lately first, or nil until they've been
    /// fetched.
    func candidates(in repository: String) -> [Reviewer]? {
        let key = repository.lowercased()
        return fetched[key].map { ReviewerRanking.ranked($0, lastRequested: lastRequested[key] ?? [:]) }
    }

    /// Fetches the candidates in `repository` unless they already have been, and reads who was
    /// asked there lately from `store`. A failed fetch isn't kept, so the next call asks again.
    func fetch(_ repository: String, store: PullRequestStore) async throws {
        let key = repository.lowercased()
        readLastRequested(key, from: store)
        if fetched[key] != nil { return }
        if let task = fetching[key] {
            _ = try await task.value
            return
        }
        let client = client
        let task = Task { try await client.reviewerCandidates(in: repository) }
        fetching[key] = task
        defer { fetching[key] = nil }
        fetched[key] = try await task.value
    }

    /// Notes that GitHub has accepted asking `reviewer` on the PR with `pullRequestId`, in the
    /// store and in the order offered from now on.
    func recordRequest(of reviewer: Reviewer, in repository: String, on pullRequestId: String, store: PullRequestStore) async {
        let key = repository.lowercased()
        let now = Date.now
        // So the earlier history isn't left unread behind this one request.
        readLastRequested(key, from: store)
        lastRequested[key, default: [:]][reviewer.id] = now
        do {
            try await store.recordReviewRequest(of: reviewer, in: repository, on: pullRequestId, at: now)
        } catch {
            log("Couldn't store the review request of \(reviewer.login) in \(repository): \(error)")
        }
    }

    private func readLastRequested(_ key: String, from store: PullRequestStore) {
        guard lastRequested[key] == nil else { return }
        do {
            lastRequested[key] = try store.lastReviewRequests(in: key)
        } catch {
            log("Couldn't read who was asked to review in \(key): \(error)")
            lastRequested[key] = [:]
        }
    }
}

/// The order reviewers are offered in. For now, whoever was asked most recently in the repo
/// comes first, then the rest in GitHub's order; spreading reviews around and GitHub's
/// suggested reviewers are to be weighed in here too.
enum ReviewerRanking {
    static func ranked(_ candidates: [Reviewer], lastRequested: [String: Date]) -> [Reviewer] {
        candidates.enumerated()
            .sorted { a, b in
                switch (lastRequested[a.element.id], lastRequested[b.element.id]) {
                case let (aDate?, bDate?) where aDate != bDate: aDate > bDate
                case (_?, nil): true
                case (nil, _?): false
                default: a.offset < b.offset
                }
            }
            .map(\.element)
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
