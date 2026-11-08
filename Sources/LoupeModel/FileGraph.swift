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

/// The changed files and which of them use which, for listing them in dependency order. Files
/// joined by use, however indirectly, are grouped, largest group first; those using and used by
/// none of the others come last, as one standalone group. Ties, and files that use each other
/// in a cycle, keep the order the directory tree lists them in, so files with no dependencies
/// between them list as the tree does.
public struct FileGraph: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        public let files: [String]
        /// Whether these are the files using and used by none of the others.
        public let isStandalone: Bool

        public init(files: [String], isStandalone: Bool) {
            self.files = files
            self.isStandalone = isStandalone
        }
    }

    /// The files in the tree's order.
    public let files: [String]
    /// The files each file uses, by path, only among `files` and never itself.
    public let dependencies: [String: Set<String>]

    /// `dependencies` names the files each one uses; any outside `paths` are left out.
    public init(paths: some Sequence<String>, dependencies: [String: Set<String>]) {
        files = FileTree(paths: paths).files
        let known = Set(files)
        self.dependencies = dependencies.reduce(into: [:]) { kept, entry in
            guard known.contains(entry.key) else { return }
            let used = entry.value.filter { known.contains($0) && $0 != entry.key }
            if !used.isEmpty { kept[entry.key] = used }
        }
    }

    /// The files `path` is used by.
    public func dependents(of path: String) -> Set<String> {
        Set(dependencies.compactMap { $0.value.contains(path) ? $0.key : nil })
    }

    /// The files in groups, each ordered as `order` asks, then the standalone files. The tree's
    /// order for `.directories`, as one standalone group.
    public func groups(_ order: FileOrder) -> [Group] {
        guard order != .directories else { return files.isEmpty ? [] : [Group(files: files, isStandalone: true)] }
        let graph = IndexedGraph(files: files, dependencies: dependencies)
        let components = graph.components()
        let joined = components.filter { $0.count > 1 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
            .map { Group(files: graph.ordered($0, usersFirst: order == .topDown).map { files[$0] }, isStandalone: false) }
        let standalone = components.filter { $0.count == 1 }.map { files[$0[0]] }.sorted { position[$0]! < position[$1]! }
        return joined + (standalone.isEmpty ? [] : [Group(files: standalone, isStandalone: true)])
    }

    /// The files in the order `order` lists them, groups one after another.
    public func ordered(_ order: FileOrder) -> [String] {
        groups(order).flatMap(\.files)
    }

    private var position: [String: Int] {
        Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1, $0) })
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
