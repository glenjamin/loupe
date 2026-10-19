import Foundation

/// How the open PRs Loupe knows of stack on one another. A PR is stacked on the open PR whose
/// head branch is its base branch, in the same repo. Where GitHub has linked PRs in a stack its
/// order is followed, so a PR sits on the open member below it; members since merged drop out,
/// as do merged or closed PRs whatever their branches. A PR can have more than one PR stacked
/// on it only through branches, as GitHub's own stacks are a single line.
public struct PullRequestStacks: Sendable {
    private let byId: [String: PullRequestSummary]
    private let parents: [String: String]
    private let children: [String: [PullRequestSummary]]

    /// From every PR known, in any list or none; a PR given twice is taken the first time.
    public init(_ pullRequests: [PullRequestSummary]) {
        var byId: [String: PullRequestSummary] = [:]
        for pullRequest in pullRequests where pullRequest.state == .open && byId[pullRequest.id] == nil {
            byId[pullRequest.id] = pullRequest
        }
        let open = byId.values.sorted { $0.number < $1.number }
        var parents: [String: String] = [:]
        for pullRequest in open {
            if let parent = Self.parent(of: pullRequest, among: open, byId: byId) { parents[pullRequest.id] = parent.id }
        }
        // A branch loop has no bottom, so none of it counts as stacked.
        for id in parents.keys where Self.isInLoop(id, parents) { parents[id] = nil }
        var children: [String: [PullRequestSummary]] = [:]
        for pullRequest in open {
            if let parent = parents[pullRequest.id] { children[parent, default: []].append(pullRequest) }
        }
        self.byId = byId
        self.parents = parents
        self.children = children
    }

    /// The open PR this one is stacked on, if any.
    public func parent(of pullRequest: PullRequestSummary) -> PullRequestSummary? {
        parents[pullRequest.id].flatMap { byId[$0] }
    }

    /// The open PRs stacked directly on this one, lowest number first.
    public func children(of pullRequest: PullRequestSummary) -> [PullRequestSummary] {
        children[pullRequest.id] ?? []
    }

    /// Whether the PR is stacked on another or has one stacked on it.
    public func isStacked(_ pullRequest: PullRequestSummary) -> Bool {
        parents[pullRequest.id] != nil || children[pullRequest.id] != nil
    }

    /// The stack as seen from `pullRequest`, for its header: the PRs below it from the bottom up,
    /// then it, then those above while there's one on each; where several PRs are stacked on the
    /// same one they're one level, side by side, and the line ends there. Nil when it isn't
    /// stacked.
    public func line(through pullRequest: PullRequestSummary) -> StackLine? {
        guard byId[pullRequest.id] != nil, isStacked(pullRequest) else { return nil }
        var below: [PullRequestSummary] = []
        var current = pullRequest
        while let parent = parent(of: current) {
            below.insert(parent, at: 0)
            current = parent
        }
        var above: [[PullRequestSummary]] = []
        var top = children(of: pullRequest)
        while !top.isEmpty {
            above.append(top)
            guard top.count == 1 else { break }
            top = children(of: top[0])
        }
        return StackLine(levels: below.map { [$0] } + [[pullRequest]] + above, current: pullRequest.id)
    }

    /// `pullRequests`, as a list orders them, with each stack's members brought together where
    /// its first member comes, in stack order from the bottom up, each indented by how many of
    /// those below it in the stack are listed. A stack's members are taken in their order of
    /// listing otherwise, so the group goes where its newest member would.
    public func grouped(_ pullRequests: [PullRequestSummary]) -> [StackedPullRequest] {
        let listed = Set(pullRequests.map(\.id))
        var placed: Set<String> = []
        var grouped: [StackedPullRequest] = []
        for pullRequest in pullRequests where !placed.contains(pullRequest.id) {
            guard isStacked(pullRequest) else {
                placed.insert(pullRequest.id)
                grouped.append(StackedPullRequest(pullRequest: pullRequest, depth: 0, parent: nil))
                continue
            }
            for member in members(from: bottom(of: pullRequest)) where listed.contains(member.id) && !placed.contains(member.id) {
                placed.insert(member.id)
                let entry = pullRequests.first { $0.id == member.id } ?? member
                let depth = ancestors(of: member).count { listed.contains($0.id) }
                grouped.append(StackedPullRequest(pullRequest: entry, depth: depth, parent: parent(of: member)))
            }
        }
        return grouped
    }

    /// Below this one, nearest first.
    private func ancestors(of pullRequest: PullRequestSummary) -> [PullRequestSummary] {
        var ancestors: [PullRequestSummary] = []
        var current = pullRequest
        while let parent = parent(of: current) {
            ancestors.append(parent)
            current = parent
        }
        return ancestors
    }

    private func bottom(of pullRequest: PullRequestSummary) -> PullRequestSummary {
        ancestors(of: pullRequest).last ?? pullRequest
    }

    /// The PR and everything stacked on it, each before those on it.
    private func members(from pullRequest: PullRequestSummary) -> [PullRequestSummary] {
        [pullRequest] + children(of: pullRequest).flatMap(members)
    }

    /// In a GitHub stack, the open member nearest below; failing that, the open PR whose head is
    /// the PR's base, as GitHub said or as the PRs known show.
    private static func parent(of pullRequest: PullRequestSummary, among open: [PullRequestSummary], byId: [String: PullRequestSummary]) -> PullRequestSummary? {
        if let stackId = pullRequest.stackId, let position = pullRequest.stackPosition,
           let below = open.filter({ $0.stackId == stackId && ($0.stackPosition ?? .max) < position }).max(by: { ($0.stackPosition ?? 0) < ($1.stackPosition ?? 0) }) {
            return below
        }
        if let id = pullRequest.stackParentId, let parent = byId[id], parent.id != pullRequest.id {
            return parent
        }
        return open.first {
            $0.id != pullRequest.id && $0.repository.caseInsensitiveCompare(pullRequest.repository) == .orderedSame && $0.headRefName == pullRequest.baseRefName
        }
    }

    private static func isInLoop(_ id: String, _ parents: [String: String]) -> Bool {
        var seen: Set<String> = [id]
        var current = id
        while let parent = parents[current] {
            if !seen.insert(parent).inserted { return true }
            current = parent
        }
        return false
    }
}

/// A stack from one PR's point of view: each level's PRs, bottom first, one PR a level except
/// where several are stacked on the same one.
public struct StackLine: Sendable, Equatable {
    public let levels: [[PullRequestSummary]]
    /// The id of the PR it's seen from.
    public let current: String

    public init(levels: [[PullRequestSummary]], current: String) {
        self.levels = levels
        self.current = current
    }
}

/// A listed PR with its place in its stack, if it's in one.
public struct StackedPullRequest: Sendable, Equatable, Identifiable {
    public let pullRequest: PullRequestSummary
    /// How many of the PRs below it in its stack are listed beside it.
    public let depth: Int
    /// The open PR it's stacked on, listed or not.
    public let parent: PullRequestSummary?

    public var id: String { pullRequest.id }

    public init(pullRequest: PullRequestSummary, depth: Int, parent: PullRequestSummary?) {
        self.pullRequest = pullRequest
        self.depth = depth
        self.parent = parent
    }
}
