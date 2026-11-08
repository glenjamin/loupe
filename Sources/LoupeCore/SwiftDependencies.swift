import CodeEditLanguages
import Foundation

/// Swift's imports: a SwiftPM package's `Sources/X` and `Tests/X` directories are targets, and
/// `import X` names target X of the same package, so a file uses that target's changed files.
/// Within a target, with no imports between its files, a file uses those defining the
/// top-level types and protocols it names. Targets placed elsewhere by `path:` aren't known.
struct SwiftDependencies: DependencyLanguage {
    func filesToRead(among paths: [String]) -> [String] {
        paths.filter { target(of: $0) != nil }
    }

    func dependencies(among paths: [String], contents: [String: String]) -> [String: Set<String>] {
        var targets: [Target: [String]] = [:]
        var definers: [Target: [String: Set<String>]] = [:]
        var parsed: [String: (modules: Set<String>, references: Set<String>)] = [:]
        for path in paths {
            guard let target = target(of: path), let text = contents[path] else { continue }
            targets[target, default: []].append(path)
            var modules = Set<String>()
            var references = Set<String>()
            for capture in Self.names?.captures(in: text) ?? [] {
                switch capture.name {
                case "module": modules.insert(String(capture.text.prefix { $0 != "." }))
                case "definition": definers[target, default: [:]][capture.text, default: []].insert(path)
                default: references.insert(capture.text)
                }
            }
            parsed[path] = (modules, references)
        }
        var dependencies: [String: Set<String>] = [:]
        for (path, names) in parsed {
            guard let target = target(of: path) else { continue }
            var used = Set<String>()
            for module in names.modules {
                used.formUnion(targets[Target(package: target.package, kind: "Sources", name: module)] ?? [])
            }
            for name in names.references { used.formUnion(definers[target]?[name] ?? []) }
            used.remove(path)
            if !used.isEmpty { dependencies[path] = used }
        }
        return dependencies
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
}
