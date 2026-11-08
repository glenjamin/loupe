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
/// none of the others come last, as one standalone group. A test named for a file in its group
/// comes straight after that file, either way up, so each is read with what it tests. Ties, and
/// files that use each other
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
            .map { Group(files: placingTests(graph.ordered($0, usersFirst: order == .topDown).map { files[$0] }), isStandalone: false) }
        let standalone = components.filter { $0.count == 1 }.map { files[$0[0]] }.sorted { position[$0]! < position[$1]! }
        return joined + (standalone.isEmpty ? [] : [Group(files: standalone, isStandalone: true)])
    }

    /// The files in the order `order` lists them, groups one after another.
    public func ordered(_ order: FileOrder) -> [String] {
        groups(order).flatMap(\.files)
    }

    /// `ordered` with each test that's named for one of its other files moved to straight after it.
    private func placingTests(_ ordered: [String]) -> [String] {
        let present = Set(ordered)
        var tests: [String: [String]] = [:]
        for path in ordered {
            if let subject = testSubject(of: path, among: present) { tests[subject, default: []].append(path) }
        }
        let moved = Set(tests.values.joined())
        return ordered.filter { !moved.contains($0) }.flatMap { [$0] + (tests[$0] ?? []) }
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

/// The file among `present` that `path` is named as the test of: `x_test.go` for `x.go`,
/// `x.test.ts` or `x.spec.ts` for `x.ts` (beside it, or above a `__tests__` directory),
/// `XTests.swift` for `X.swift`, `x_spec.rb` for `x.rb` and `test_x.py` for `x.py`; one
/// named alike elsewhere if there's just one. Nil when it isn't a test, or there's no such file.
private func testSubject(of path: String, among present: Set<String>) -> String? {
    let name = (path as NSString).lastPathComponent
    let directory = (path as NSString).deletingLastPathComponent
    var stems: [String] = []
    var extensions: [String] = []
    let scriptExtensions = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts"]
    let parts = name.split(separator: ".").map(String.init)
    if name.hasSuffix("_test.go") {
        stems = [String(name.dropLast("_test.go".count))]
        extensions = ["go"]
    } else if parts.count >= 3, ["test", "spec"].contains(parts[parts.count - 2]), scriptExtensions.contains(parts[parts.count - 1]) {
        stems = [parts.dropLast(2).joined(separator: ".")]
        extensions = scriptExtensions
    } else if name.hasSuffix("Tests.swift") || name.hasSuffix("Test.swift") {
        stems = [String(name.dropLast(name.hasSuffix("Tests.swift") ? "Tests.swift".count : "Test.swift".count))]
        extensions = ["swift"]
    } else if name.hasSuffix("_spec.rb") || name.hasSuffix("_test.rb") {
        stems = [String(name.dropLast("_spec.rb".count))]
        extensions = ["rb"]
    } else if name.hasPrefix("test_"), name.hasSuffix(".py") {
        stems = [String(name.dropFirst("test_".count).dropLast(".py".count))]
        extensions = ["py"]
    }
    guard let stem = stems.first, !stem.isEmpty else { return nil }
    let names = extensions.map { "\(stem).\($0)" }
    var directories = [directory]
    if (directory as NSString).lastPathComponent == "__tests__" { directories.append((directory as NSString).deletingLastPathComponent) }
    for candidateDirectory in directories {
        for candidate in names {
            let full = candidateDirectory.isEmpty ? candidate : "\(candidateDirectory)/\(candidate)"
            if full != path, present.contains(full) { return full }
        }
    }
    let elsewhere = present.filter { $0 != path && names.contains(($0 as NSString).lastPathComponent) }
    return elsewhere.count == 1 ? elsewhere.first : nil
}
