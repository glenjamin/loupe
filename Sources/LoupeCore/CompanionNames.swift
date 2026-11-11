import Foundation
import LoupeModel

/// Files named as another's companions: `x.d.ts` declares `x.js`; `x.stories.tsx` or
/// `x.story.tsx` is a story of `x.tsx`; and tests, `x_test.go` of `x.go`, `x.test.ts` or
/// `x.spec.ts` of `x.ts` (beside it, or above a `__tests__` directory), `XTests.swift` of
/// `X.swift`, `x_spec.rb` of `x.rb` and `test_x.py` of `x.py`, or, but for Go's, of one named
/// alike elsewhere if there's just one.
struct CompanionNames: DependencyRule {
    func links(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        let present = Set(paths)
        let byName = Dictionary(grouping: paths) { ($0 as NSString).lastPathComponent }
        return paths.compactMap { path in
            companion(of: path, among: present, byName: byName).map { DependencyLink(from: path, to: $0.subject, reason: $0.reason) }
        }
    }

    /// The file among `present` that `path` is named as a companion of, and how.
    private func companion(of path: String, among present: Set<String>, byName: [String: [String]]) -> (subject: String, reason: DependencyLink.Reason)? {
        guard let naming = TestNaming(path) else { return nil }
        let names = naming.extensions.map { "\(naming.stem).\($0)" }
        var directories = [directory(of: path)]
        if (directory(of: path) as NSString).lastPathComponent == "__tests__" { directories.append(directory(of: directory(of: path))) }
        for candidateDirectory in directories {
            for candidate in names {
                let full = joined(candidateDirectory, candidate)
                if full != path, present.contains(full) { return (full, naming.reason) }
            }
        }
        // A declaration names its file exactly, and a Go test is of its own package; others may
        // be named alike elsewhere.
        guard naming.reason != .declares, !path.hasSuffix(".go") else { return nil }
        let elsewhere = names.flatMap { byName[$0] ?? [] }.filter { $0 != path }
        return elsewhere.count == 1 ? elsewhere.first.map { ($0, naming.reason) } : nil
    }
}

/// How a companion's name names its subject: the stem and extensions the subject may have.
struct TestNaming {
    let stem: String
    let extensions: [String]
    let reason: DependencyLink.Reason

    init?(_ path: String) {
        let name = (path as NSString).lastPathComponent
        let scriptExtensions = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts"]
        let parts = name.split(separator: ".").map(String.init)
        if parts.count >= 3, parts[parts.count - 2] == "d", ["ts", "mts", "cts"].contains(parts[parts.count - 1]) {
            (stem, extensions, reason) = (parts.dropLast(2).joined(separator: "."), ["js", "jsx", "mjs", "cjs"], .declares)
        } else if parts.count >= 3, ["stories", "story"].contains(parts[parts.count - 2]), (scriptExtensions + ["mdx"]).contains(parts[parts.count - 1]) {
            (stem, extensions, reason) = (parts.dropLast(2).joined(separator: "."), scriptExtensions, .story)
        } else if name.hasSuffix("_test.go") {
            (stem, extensions, reason) = (String(name.dropLast("_test.go".count)), ["go"], .tests)
        } else if parts.count >= 3, ["test", "spec"].contains(parts[parts.count - 2]), scriptExtensions.contains(parts[parts.count - 1]) {
            (stem, extensions, reason) = (parts.dropLast(2).joined(separator: "."), scriptExtensions, .tests)
        } else if name.hasSuffix("Tests.swift") || name.hasSuffix("Test.swift") {
            (stem, extensions, reason) = (String(name.dropLast(name.hasSuffix("Tests.swift") ? "Tests.swift".count : "Test.swift".count)), ["swift"], .tests)
        } else if name.hasSuffix("_spec.rb") || name.hasSuffix("_test.rb") {
            (stem, extensions, reason) = (String(name.dropLast("_spec.rb".count)), ["rb"], .tests)
        } else if name.hasPrefix("test_"), name.hasSuffix(".py") {
            (stem, extensions, reason) = (String(name.dropFirst("test_".count).dropLast(".py".count)), ["py"], .tests)
        } else {
            return nil
        }
        guard !stem.isEmpty else { return nil }
    }
}

/// A README describes the changed files beside it, and follows them.
struct Readmes: DependencyRule {
    func links(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        let byDirectory = Dictionary(grouping: paths, by: directory(of:))
        var links = LinkCollector()
        for readme in paths where isReadme(readme) {
            links.add(from: readme, to: (byDirectory[directory(of: readme)] ?? []).filter { !isReadme($0) }, .describes)
        }
        return links.links
    }

    private func isReadme(_ path: String) -> Bool {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.caseInsensitiveCompare("readme") == .orderedSame
    }
}
