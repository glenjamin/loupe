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
/// none of the others come last, as one standalone group. A file's companions, named for it,
/// follow it either way up, ordered with it as one: its type declarations, then its stories,
/// then its tests, so each is read with what it's for; a README follows the files beside it.
/// Ties, and
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
        var kept: [String: Set<String>] = dependencies.reduce(into: [:]) { kept, entry in
            guard known.contains(entry.key) else { return }
            let used = entry.value.filter { known.contains($0) && $0 != entry.key }
            if !used.isEmpty { kept[entry.key] = used }
        }
        // A README is about the files beside it.
        let byDirectory = Dictionary(grouping: files) { ($0 as NSString).deletingLastPathComponent }
        for readme in files where isReadme(readme) {
            let beside = (byDirectory[(readme as NSString).deletingLastPathComponent] ?? []).filter { !isReadme($0) }
            if !beside.isEmpty { kept[readme, default: []].formUnion(beside) }
        }
        self.dependencies = kept
    }

    /// The files `path` is used by.
    public func dependents(of path: String) -> Set<String> {
        Set(dependencies.compactMap { $0.value.contains(path) ? $0.key : nil })
    }

    /// The files in groups, each ordered as `order` asks, then the standalone files. The tree's
    /// order for `.directories`, as one standalone group.
    public func groups(_ order: FileOrder) -> [Group] {
        guard order != .directories else { return files.isEmpty ? [] : [Group(files: files, isStandalone: true)] }
        // Each file and its companions are ordered as one, then follow it in turn.
        let present = Set(files)
        let byName = Dictionary(grouping: files) { ($0 as NSString).lastPathComponent }
        let companions = Dictionary(uniqueKeysWithValues: files.compactMap { path in companion(of: path, among: present, byName: byName).map { (path, $0) } })
        func subject(of path: String) -> String {
            var current = path
            var seen: Set<String> = [path]
            while let next = companions[current]?.subject, seen.insert(next).inserted { current = next }
            return current
        }
        let subjects = files.filter { companions[$0] == nil || subject(of: $0) == $0 }
        var following: [String: [String]] = [:]
        for path in files where !subjects.contains(path) { following[subject(of: path), default: []].append(path) }
        for (subject, paths) in following { following[subject] = paths.sorted { companions[$0]!.kind < companions[$1]!.kind } }
        var contracted: [String: Set<String>] = [:]
        for (path, used) in dependencies {
            for dependency in used where subject(of: dependency) != subject(of: path) { contracted[subject(of: path), default: []].insert(subject(of: dependency)) }
        }
        let graph = IndexedGraph(files: subjects, dependencies: contracted)
        func expanded(_ indices: [Int]) -> [String] {
            indices.flatMap { [subjects[$0]] + (following[subjects[$0]] ?? []) }
        }
        let components = graph.components().map { (indices: $0, size: expanded($0).count) }
        let joined = components.filter { $0.size > 1 }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.indices[0] < $1.indices[0] }
            .map { Group(files: placingReadmes(expanded(graph.ordered($0.indices, usersFirst: order == .topDown))), isStandalone: false) }
        let standalone = components.filter { $0.size == 1 }.map(\.indices[0]).sorted().map { subjects[$0] }
        return joined + (standalone.isEmpty ? [] : [Group(files: standalone, isStandalone: true)])
    }

    public func ordered(_ order: FileOrder) -> [String] {
        groups(order).flatMap(\.files)
    }

    /// `ordered` with each README moved to after the last of the files beside it.
    private func placingReadmes(_ ordered: [String]) -> [String] {
        var result = ordered.filter { !isReadme($0) }
        for readme in ordered where isReadme(readme) {
            let directory = (readme as NSString).deletingLastPathComponent
            let last = result.lastIndex { ($0 as NSString).deletingLastPathComponent == directory }
            result.insert(readme, at: last.map { $0 + 1 } ?? result.endIndex)
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

/// What a companion file is to its subject, in the order they follow it.
private enum CompanionKind: Comparable {
    /// `x.d.ts`, beside `x.js`.
    case declaration
    /// `x.stories.tsx`, Storybook's, after the code and before its tests.
    case story
    case test
}

/// The file among `present` that `path` is named as a companion of, and how: `x.d.ts` for
/// `x.js`; `x.stories.tsx` or `x.story.tsx` for `x.tsx`; and as tests `x_test.go` for `x.go`,
/// `x.test.ts` or `x.spec.ts` for `x.ts` (beside it, or above a `__tests__` directory),
/// `XTests.swift` for `X.swift`, `x_spec.rb` for `x.rb` and `test_x.py` for `x.py`; one
/// named alike elsewhere if there's just one. Nil when it isn't one, or there's no such file.
private func companion(of path: String, among present: Set<String>, byName: [String: [String]]) -> (subject: String, kind: CompanionKind)? {
    let name = (path as NSString).lastPathComponent
    let directory = (path as NSString).deletingLastPathComponent
    let scriptExtensions = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts"]
    let parts = name.split(separator: ".").map(String.init)
    let stem: String
    let extensions: [String]
    let kind: CompanionKind
    if parts.count >= 3, parts[parts.count - 2] == "d", ["ts", "mts", "cts"].contains(parts[parts.count - 1]) {
        (stem, extensions, kind) = (parts.dropLast(2).joined(separator: "."), ["js", "jsx", "mjs", "cjs"], .declaration)
    } else if parts.count >= 3, ["stories", "story"].contains(parts[parts.count - 2]), (scriptExtensions + ["mdx"]).contains(parts[parts.count - 1]) {
        (stem, extensions, kind) = (parts.dropLast(2).joined(separator: "."), scriptExtensions, .story)
    } else if name.hasSuffix("_test.go") {
        (stem, extensions, kind) = (String(name.dropLast("_test.go".count)), ["go"], .test)
    } else if parts.count >= 3, ["test", "spec"].contains(parts[parts.count - 2]), scriptExtensions.contains(parts[parts.count - 1]) {
        (stem, extensions, kind) = (parts.dropLast(2).joined(separator: "."), scriptExtensions, .test)
    } else if name.hasSuffix("Tests.swift") || name.hasSuffix("Test.swift") {
        (stem, extensions, kind) = (String(name.dropLast(name.hasSuffix("Tests.swift") ? "Tests.swift".count : "Test.swift".count)), ["swift"], .test)
    } else if name.hasSuffix("_spec.rb") || name.hasSuffix("_test.rb") {
        (stem, extensions, kind) = (String(name.dropLast("_spec.rb".count)), ["rb"], .test)
    } else if name.hasPrefix("test_"), name.hasSuffix(".py") {
        (stem, extensions, kind) = (String(name.dropFirst("test_".count).dropLast(".py".count)), ["py"], .test)
    } else {
        return nil
    }
    guard !stem.isEmpty else { return nil }
    let names = extensions.map { "\(stem).\($0)" }
    var directories = [directory]
    if (directory as NSString).lastPathComponent == "__tests__" { directories.append((directory as NSString).deletingLastPathComponent) }
    for candidateDirectory in directories {
        for candidate in names {
            let full = candidateDirectory.isEmpty ? candidate : "\(candidateDirectory)/\(candidate)"
            if full != path, present.contains(full) { return (full, kind) }
        }
    }
    // A declaration names its file exactly; others may be named alike elsewhere.
    guard kind != .declaration else { return nil }
    let elsewhere = names.flatMap { byName[$0] ?? [] }.filter { $0 != path }
    return elsewhere.count == 1 ? elsewhere.first.map { ($0, kind) } : nil
}

/// Whether `path` is a README, of whatever format.
private func isReadme(_ path: String) -> Bool {
    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    return name.caseInsensitiveCompare("readme") == .orderedSame
}
