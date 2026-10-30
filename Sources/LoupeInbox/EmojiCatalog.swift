import Foundation
import LoupeGitHub
import LoupeModel
import Observation

/// The emoji GitHub's markdown takes, fetched once a run and shared by every tab, for the comment
/// boxes to complete `:` and a name. The list only changes with GitHub's releases.
@Observable
@MainActor
final class EmojiCatalog {
    private(set) var emojis: [Emoji] = []
    /// The fetch on its way, shared by everyone asking meanwhile.
    @ObservationIgnored private var fetching: Task<[Emoji], any Error>?
    private let client: GitHubClient

    init(client: GitHubClient) {
        self.client = client
    }

    /// Fetches the list unless it has been. A failure is logged and not kept, so the next box
    /// opened asks again; meanwhile nothing is offered.
    func fetch() async {
        guard emojis.isEmpty else { return }
        if let fetching {
            _ = try? await fetching.value
            return
        }
        let client = client
        let task = Task { try await client.emojis() }
        fetching = task
        defer { fetching = nil }
        do {
            emojis = try await task.value
        } catch {
            log("Couldn't fetch GitHub's emoji: \(error)")
        }
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
