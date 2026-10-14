import LoupeGitHub
import LoupeModel
import Observation

/// Who can be asked to review in each repo, fetched from GitHub once a run and shared by every
/// tab, so the request-a-review search filters them as the viewer types rather than asking
/// GitHub each time. A repo's people and teams rarely change while the app runs.
@Observable
@MainActor
final class ReviewerCandidates {
    /// Each repo's candidates once fetched, by lowercased `owner/name`.
    private var fetched: [String: [Reviewer]] = [:]
    /// Fetches on their way, shared by everyone asking for the same repo meanwhile.
    @ObservationIgnored private var fetching: [String: Task<[Reviewer], any Error>] = [:]
    private let client: GitHubClient

    init(client: GitHubClient) {
        self.client = client
    }

    /// The candidates in `repository`, or nil until they've been fetched.
    func candidates(in repository: String) -> [Reviewer]? {
        fetched[repository.lowercased()]
    }

    /// Fetches the candidates in `repository` unless they already have been. A failure isn't
    /// kept, so the next call asks again.
    func fetch(_ repository: String) async throws {
        let key = repository.lowercased()
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
}
