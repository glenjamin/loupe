import CodeEditLanguages
import Foundation
import LoupeModel

/// Swift's imports: a SwiftPM package's `Sources/X` and `Tests/X` directories are targets, and
/// `import X` names target X of the same package, so a file uses that target's changed files.
/// Within a target, with no imports between its files, a file uses those defining the
/// top-level types and protocols it names. Targets placed elsewhere by `path:` aren't known.
struct SwiftDependencies: DependencyRule {
    func filesToRead(among paths: [String]) -> [String] {
        paths.filter { target(of: $0) != nil }
    }

    func links(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        var targets: [Target: [String]] = [:]
        var definitions = NameIndex()
        var parsed: [String: (modules: Set<String>, references: Set<String>)] = [:]
        let sources = paths.filter { target(of: $0) != nil && contents[$0] != nil }
        let captures = concurrentMap(sources) { path in Self.names?.captures(in: contents[path] ?? "") ?? [] }
        for (path, found) in zip(sources, captures) {
            guard let target = target(of: path) else { continue }
            targets[target, default: []].append(path)
            var modules = Set<String>()
            var references = Set<String>()
            for capture in found {
                switch capture.name {
                case "module": modules.insert(String(capture.text.prefix { $0 != "." }))
                case "definition": definitions.define(capture.text, in: path, scope: target.scope)
                default: references.insert(capture.text)
                }
            }
            parsed[path] = (modules, references)
        }
        var links = LinkCollector()
        for (path, names) in parsed {
            guard let target = target(of: path) else { continue }
            for module in names.modules {
                links.add(from: path, to: targets[Target(package: target.package, kind: "Sources", name: module)] ?? [], .imports)
            }
            for name in names.references { links.add(from: path, to: definitions.definers(of: name, in: target.scope), .names) }
        }
        return links.links
    }

    private static let names = ImportQuery(TreeSitterLanguage.swift.tsLanguage, """
        (import_declaration (identifier) @module)
        (source_file (class_declaration name: (type_identifier) @definition))
        (source_file (protocol_declaration name: (type_identifier) @definition))
        (type_identifier) @reference
        (simple_identifier) @reference
        """)

    /// The SwiftPM target `path` is in, by its package's directory, nil if it isn't Swift in one.
    private func target(of path: String) -> Target? {
        guard path.hasSuffix(".swift") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.dropLast(2).lastIndex(where: { $0 == "Sources" || $0 == "Tests" }) else { return nil }
        return Target(package: components[..<index].joined(separator: "/"), kind: components[index], name: components[index + 1])
    }
}

private struct Target: Hashable {
    let package: String
    /// `Sources` or `Tests`.
    let kind: String
    let name: String

    /// A name for the target as a scope of names.
    var scope: String { "\(package)/\(kind)/\(name)" }
}
