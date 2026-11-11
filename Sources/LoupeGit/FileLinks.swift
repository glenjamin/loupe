import Foundation
import LoupeCore
import LoupeModel

extension PullRequestDiffer {
    /// The links among `files`, the changes over `range`: as the range's head has them, and for
    /// the files it deletes, as its base had them, both a deleted file's own links and those to
    /// it, a renamed file going by its old path there, so a deleted file joins the files it
    /// belonged with.
    public func links(among files: [FileDiff], over range: DiffRange, in checkout: URL) async throws -> [DependencyLink] {
        var links = try await links(among: files.map(\.path), at: range.head, in: checkout)
        let deleted = Set(files.filter { $0.change == .deleted }.map(\.path))
        guard !deleted.isEmpty else { return links }
        // Each file the base had, by its path there, as it's listed now.
        var current: [String: String] = [:]
        for file in files {
            switch file.change {
            case .added, .copied: continue
            case let .renamed(from, _): current[from] = file.path
            case .deleted, .modified: current[file.path] = file.path
            }
        }
        for link in try await self.links(among: Array(current.keys), at: range.base, in: checkout) where deleted.contains(link.from) || deleted.contains(link.to) {
            if let from = current[link.from], let to = current[link.to] { links.append(DependencyLink(from: from, to: to, reason: link.reason)) }
        }
        return links
    }

    /// The range `base...head` names, from where `head` branched off `base` up to `head`, as a
    /// PR's changes are, with both resolved to commits.
    public func branchRange(base: String, head: String, in checkout: URL) async throws -> DiffRange {
        async let headOid = Git.run(["rev-parse", "--verify", "\(head)^{commit}"], in: checkout)
        async let mergeBase = Git.run(["merge-base", base, head], in: checkout)
        return DiffRange(base: try await mergeBase.trimmingCharacters(in: .whitespacesAndNewlines), head: try await headOid.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func links(among paths: [String], at oid: String, in checkout: URL) async throws -> [DependencyLink] {
        let wanted = FileDependencies.filesToRead(among: paths)
        async let contents = wanted.isEmpty ? [:] : contents(of: wanted, at: oid, in: checkout, limit: FileDependencies.largestFile)
        async let listings = files(in: FileDependencies.directoriesToList(among: paths), at: oid, in: checkout)
        let (read, listed) = try await (contents, listings)
        return await Task.detached { FileDependencies.find(among: paths, contents: read, listings: listed) }.value
    }
}
