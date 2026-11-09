import Foundation

/// How the files to review are listed: as a tree of their directories, or in the order their
/// dependencies on each other give, read from the files using others down to those they use,
/// or the other way up.
public enum FileOrder: Sendable, Hashable, CaseIterable {
    case directories
    /// Each file before those it uses.
    case topDown
    /// Each file after those it uses.
    case bottomUp
}

/// The changed files and the links between them, for listing them in dependency order. Files
/// joined by links, however indirectly, are grouped, largest group first; those linked to none
/// of the others come last, as one standalone group. A file's companions follow it either way
/// up, ordered with it as one: its type declarations, then its stories, then its tests, so each
/// is read with what it's for; a README follows the last of the files it describes. Ties, and
/// files that use each other in a cycle, keep the order the directory tree lists them in, so
/// files with no links between them list as the tree does.
public struct FileGraph: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        public let files: [String]
        /// Whether these are the files linked to none of the others.
        public let isStandalone: Bool

        public init(files: [String], isStandalone: Bool) {
            self.files = files
            self.isStandalone = isStandalone
        }
    }

    /// The files in the tree's order.
    public let files: [String]
    /// The links between `files`, never from a file to itself.
    public let links: [DependencyLink]
    /// The files each file is linked to, by path.
    public let dependencies: [String: Set<String>]
    /// Whether any files are joined into a group rather than every one standing alone.
    public private(set) var isLinked = false

    /// Links to or from files outside `paths` are left out.
    public init(paths: some Sequence<String>, links: some Sequence<DependencyLink>) {
        files = FileTree(paths: paths).files
        let known = Set(files)
        var seen = Set<DependencyLink>()
        self.links = links.filter { known.contains($0.from) && known.contains($0.to) && $0.from != $0.to && seen.insert($0).inserted }
        dependencies = self.links.reduce(into: [:]) { $0[$1.from, default: []].insert($1.to) }
        isLinked = groups(.topDown).contains { !$0.isStandalone }
    }

    /// `dependencies` names the files each one uses, by import.
    public init(paths: some Sequence<String>, dependencies: [String: Set<String>]) {
        self.init(paths: paths, links: dependencies.flatMap { file, used in used.map { DependencyLink(from: file, to: $0, reason: .imports) } })
    }

    /// The files `path` is used by.
    public func dependents(of path: String) -> Set<String> {
        Set(links.filter { $0.to == path }.map(\.from))
    }

    /// The files in groups, each ordered as `order` asks, then the standalone files. The tree's
    /// order for `.directories`, as one standalone group.
    public func groups(_ order: FileOrder) -> [Group] {
        guard order != .directories else { return files.isEmpty ? [] : [Group(files: files, isStandalone: true)] }
        let position = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1, $0) })
        // Each file and its companions are ordered as one, then follow it in turn.
        var companions: [String: (subject: String, reason: DependencyLink.Reason)] = [:]
        for link in links where link.reason.isCompanion {
            if let existing = companions[link.from], (existing.reason, position[existing.subject]!) <= (link.reason, position[link.to]!) { continue }
            companions[link.from] = (link.to, link.reason)
        }
        func subject(of path: String) -> String {
            var current = path
            var seen: Set<String> = [path]
            while let next = companions[current]?.subject, seen.insert(next).inserted { current = next }
            return current
        }
        let subjects = files.filter { subject(of: $0) == $0 }
        var following: [String: [String]] = [:]
        for path in files where subject(of: path) != path { following[subject(of: path), default: []].append(path) }
        for (subject, paths) in following { following[subject] = paths.sorted { companions[$0]!.reason < companions[$1]!.reason } }
        var contracted: [String: Set<String>] = [:]
        for link in links where subject(of: link.to) != subject(of: link.from) {
            contracted[subject(of: link.from), default: []].insert(subject(of: link.to))
        }
        let graph = IndexedGraph(files: subjects, dependencies: contracted)
        func expanded(_ indices: [Int]) -> [String] {
            indices.flatMap { [subjects[$0]] + (following[subjects[$0]] ?? []) }
        }
        let components = graph.components().map { (indices: $0, size: expanded($0).count) }
        let joined = components.filter { $0.size > 1 }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.indices[0] < $1.indices[0] }
            .map { Group(files: placingDescriptions(expanded(graph.ordered($0.indices, usersFirst: order == .topDown))), isStandalone: false) }
        let standalone = components.filter { $0.size == 1 }.map(\.indices[0]).sorted().map { subjects[$0] }
        return joined + (standalone.isEmpty ? [] : [Group(files: standalone, isStandalone: true)])
    }

    public func ordered(_ order: FileOrder) -> [String] {
        groups(order).flatMap(\.files)
    }

    /// `ordered` with each file describing others, a README, moved to after the last of them.
    private func placingDescriptions(_ ordered: [String]) -> [String] {
        let described = links.filter { $0.reason == .describes }.reduce(into: [String: Set<String>]()) { $0[$1.from, default: []].insert($1.to) }
        var result = ordered.filter { described[$0] == nil }
        for path in ordered {
            guard let subjects = described[path] else { continue }
            let last = result.lastIndex { subjects.contains($0) }
            result.insert(path, at: last.map { $0 + 1 } ?? result.endIndex)
        }
        return result
    }
}

/// The graph by the files' places in the tree's order, with edges from each file to those it uses.
private struct IndexedGraph {
    let uses: [[Int]]
    let usedBy: [[Int]]

    init(files: [String], dependencies: [String: Set<String>]) {
        let position = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1, $0) })
        var uses = Array(repeating: [Int](), count: files.count)
        var usedBy = uses
        for (file, used) in dependencies {
            guard let from = position[file] else { continue }
            for to in used.compactMap({ position[$0] }).sorted() {
                uses[from].append(to)
                usedBy[to].append(from)
            }
        }
        self.uses = uses
        self.usedBy = usedBy
    }

    /// The files joined by use in either direction, each ascending, as are the first files of each.
    func components() -> [[Int]] {
        var seen = Array(repeating: false, count: uses.count)
        var components: [[Int]] = []
        for start in uses.indices where !seen[start] {
            var component: [Int] = []
            var stack = [start]
            seen[start] = true
            while let node = stack.popLast() {
                component.append(node)
                for next in uses[node] + usedBy[node] where !seen[next] {
                    seen[next] = true
                    stack.append(next)
                }
            }
            components.append(component.sorted())
        }
        return components
    }

    /// `component`'s files with each before those it uses, or after them: cycles are taken as one
    /// file, whose members keep the tree's order, and among those free to go next the earliest
    /// in the tree goes first.
    func ordered(_ component: [Int], usersFirst: Bool) -> [Int] {
        let cycles = stronglyConnected(component)
        var cycleOf: [Int: Int] = [:]
        for (index, members) in cycles.enumerated() {
            for member in members { cycleOf[member] = index }
        }
        // Edges between cycles, pointing at what must come after.
        var after = Array(repeating: Set<Int>(), count: cycles.count)
        for node in component {
            for used in uses[node] {
                let (from, to) = (cycleOf[node]!, cycleOf[used]!)
                guard from != to else { continue }
                if usersFirst { after[from].insert(to) } else { after[to].insert(from) }
            }
        }
        var waiting = Array(repeating: 0, count: cycles.count)
        for targets in after {
            for target in targets { waiting[target] += 1 }
        }
        var ready = cycles.indices.filter { waiting[$0] == 0 }
        var ordered: [Int] = []
        while !ready.isEmpty {
            let next = ready.indices.min { cycles[ready[$0]][0] < cycles[ready[$1]][0] }!
            let cycle = ready.remove(at: next)
            ordered += cycles[cycle]
            for target in after[cycle] {
                waiting[target] -= 1
                if waiting[target] == 0 { ready.append(target) }
            }
        }
        return ordered
    }

    /// Tarjan's strongly connected components of `component`, each ascending.
    private func stronglyConnected(_ component: [Int]) -> [[Int]] {
        var index: [Int: Int] = [:]
        var lowLink: [Int: Int] = [:]
        var onStack = Set<Int>()
        var stack: [Int] = []
        var counter = 0
        var result: [[Int]] = []

        func visit(_ node: Int) {
            index[node] = counter
            lowLink[node] = counter
            counter += 1
            stack.append(node)
            onStack.insert(node)
            for next in uses[node] {
                if index[next] == nil {
                    visit(next)
                    lowLink[node] = min(lowLink[node]!, lowLink[next]!)
                } else if onStack.contains(next) {
                    lowLink[node] = min(lowLink[node]!, index[next]!)
                }
            }
            guard lowLink[node] == index[node] else { return }
            var members: [Int] = []
            while let member = stack.popLast() {
                onStack.remove(member)
                members.append(member)
                if member == node { break }
            }
            result.append(members.sorted())
        }

        for node in component where index[node] == nil { visit(node) }
        return result
    }
}
