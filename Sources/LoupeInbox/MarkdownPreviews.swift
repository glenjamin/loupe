import Foundation
import LoupeCore
import LoupeGit
import LoupeGitHub
import Observation

/// An open PR's markdown files rendered by GitHub, for reading as github.com shows them beside
/// their diff. A file's rendering is kept by the commit it's of, so going back and forth between
/// source and rendered is instant, and which files show rendered is kept while the tab lives.
/// Drafts written on the PR are previewed by the same renderer, each text's rendering kept too.
@Observable
@MainActor
public final class MarkdownPreviews {
    private let client: GitHubClient
    private let differ: PullRequestDiffer
    /// The paths shown rendered; any other shows its diff.
    private var renderedPaths: Set<String> = []
    private var renderings: [MarkdownSource: MarkdownRendering] = [:]
    private var draftRenderings: [String: MarkdownRendering] = [:]

    init(client: GitHubClient, differ: PullRequestDiffer) {
        self.client = client
        self.differ = differ
    }

    public func isRendered(_ path: String) -> Bool {
        renderedPaths.contains(path)
    }

    public func setRendered(_ rendered: Bool, path: String) {
        if rendered {
            renderedPaths.insert(path)
        } else {
            renderedPaths.remove(path)
        }
    }

    /// The file's rendering once asked for.
    public func rendering(of source: MarkdownSource) -> MarkdownRendering? {
        renderings[source]
    }

    /// Reads the file from the checkout and has GitHub render it, unless that's done or underway.
    /// A failed rendering is tried again.
    func render(_ source: MarkdownSource, checkout: URL) async {
        switch renderings[source] {
        case .ready, .rendering: return
        case .failed, nil: break
        }
        renderings[source] = .rendering
        do {
            let text = try await differ.contents(of: source.path, at: source.oid, in: checkout)
            renderings[source] = .ready(try await client.renderMarkdown(text, in: source.repository))
        } catch {
            renderings[source] = .failed(error.localizedDescription)
        }
    }

    /// What a draft previews as: nil for a blank one, which has nothing to render, and rendering
    /// until GitHub has answered for its text.
    public func preview(ofDraft text: String) -> MarkdownRendering? {
        guard hasText(text) else { return nil }
        return draftRenderings[text] ?? .rendering
    }

    /// Has GitHub render a draft as a comment in `repository`, unless it's blank or that's done or
    /// underway. A failed rendering is tried again.
    func renderDraft(_ text: String, in repository: String) async {
        guard hasText(text) else { return }
        switch draftRenderings[text] {
        case .ready, .rendering: return
        case .failed, nil: break
        }
        draftRenderings[text] = .rendering
        do {
            draftRenderings[text] = .ready(try await client.renderMarkdown(text, in: repository))
        } catch {
            draftRenderings[text] = .failed(error.localizedDescription)
        }
    }

    private func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A markdown file as it is in one commit of a repo.
public struct MarkdownSource: Sendable, Hashable {
    /// `owner/name`, which GitHub resolves references against.
    public let repository: String
    public let path: String
    public let oid: String
}

public enum MarkdownRendering: Sendable, Equatable {
    case rendering
    /// GitHub's HTML.
    case ready(String)
    /// Why it failed.
    case failed(String)
}

extension PullRequestTab {
    /// What a markdown file in the shown changes renders: its version at their head, or for a
    /// deleted file its version at their base. Nil for any other file, or until the diff is ready.
    public func markdownSource(of file: FileDiff) -> MarkdownSource? {
        guard MarkdownHTML.isMarkdown(file.path), case let .ready(review) = phase else { return nil }
        let range = review.commits.first { $0.oid == shownCommit }?.range ?? DiffRange(base: review.mergeBase, head: review.headOid)
        return MarkdownSource(repository: pullRequest.repository, path: file.path, oid: file.change == .deleted ? range.base : range.head)
    }

    /// Renders the file, unless that's done or underway.
    public func renderMarkdown(_ source: MarkdownSource) async {
        guard let checkout else { return }
        await markdown.render(source, checkout: checkout)
    }

    /// Renders a draft written on the PR as GitHub will show it, mentions and references
    /// resolved against the PR's repo, unless it's blank or that's done or underway.
    public func renderDraft(_ text: String) async {
        await markdown.renderDraft(text, in: pullRequest.repository)
    }
}
