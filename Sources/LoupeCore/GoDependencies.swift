import CodeEditLanguages
import Foundation
import LoupeModel

/// Go's imports: an import path names a package, a directory under the module whose `go.mod`
/// is nearest above the file, so a file uses that package's changed files. Within a package,
/// with no imports between its files, a file uses those defining the top-level names it
/// refers to. Its tests use their own directory's other files, whichever package they're in,
/// and the helpers its other tests define. A string naming a changed file, such as a test's
/// fixture, uses it. Importing a package uses the `.proto` files its hidden generated code comes
/// from as its interface: those beside it, and those whose `go_package` names it.
struct GoDependencies: DependencyRule {
    func filesToRead(among paths: [String]) -> [String] {
        let sources = paths.filter(isGo)
        guard !sources.isEmpty else { return [] }
        var modules: [String] = []
        var seen = Set<String>()
        for path in sources + paths.filter(isProto) {
            for directory in ancestors(of: path) where seen.insert(directory).inserted { modules.append(joined(directory, "go.mod")) }
        }
        return sources + paths.filter(isProto) + modules
    }

    func links(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        let sources = paths.filter { isGo($0) && contents[$0] != nil }
        guard !sources.isEmpty else { return [] }
        var modules: [String: String] = [:]
        for (path, text) in contents where (path as NSString).lastPathComponent == "go.mod" {
            if let module = modulePath(in: text) { modules[directory(of: path)] = module }
        }
        // The package each directory's files make, by import path.
        var packages: [String: [String]] = [:]
        var byDirectory: [String: [String]] = [:]
        for path in sources where !isTest(path) {
            byDirectory[directory(of: path), default: []].append(path)
            if let importPath = importPath(of: directory(of: path), modules: modules) { packages[importPath, default: []].append(path) }
        }
        var interfaces: [String: [String]] = [:]
        for path in paths where isProto(path) {
            let named = contents[path].flatMap(ProtoFile.goPackage(in:))
            for importPath in Set([named, importPath(of: directory(of: path), modules: modules)].compactMap(\.self)) {
                interfaces[importPath, default: []].append(path)
            }
        }
        let parsed = Dictionary(uniqueKeysWithValues: zip(sources, concurrentMap(sources) { path in
            Self.names?.captures(in: contents[path] ?? "") ?? []
        }))
        // What each directory's files define at the top level; its tests' apart, as only tests
        // can use them.
        var definitions = NameIndex()
        var testDefinitions = NameIndex()
        for path in sources {
            for capture in parsed[path] ?? [] where capture.name == "definition" && !["_", "init", "main"].contains(capture.text) {
                if isTest(path) {
                    testDefinitions.define(capture.text, in: path, scope: directory(of: path))
                } else {
                    definitions.define(capture.text, in: path, scope: directory(of: path))
                }
            }
        }
        let changed = Set(paths)
        var links = LinkCollector()
        for path in sources {
            for capture in parsed[path] ?? [] {
                switch capture.name {
                case "path":
                    links.add(from: path, to: packages[unquoted(capture.text)] ?? [], .imports)
                    links.add(from: path, to: interfaces[unquoted(capture.text)] ?? [], .interface)
                case "reference":
                    links.add(from: path, to: definitions.definers(of: capture.text, in: directory(of: path)), .names)
                    if isTest(path) { links.add(from: path, to: testDefinitions.definers(of: capture.text, in: directory(of: path)), .names) }
                case "string": links.add(from: path, to: filesNamed(by: unquoted(capture.text), from: path, among: changed), .path)
                default: break
                }
            }
            if isTest(path) { links.add(from: path, to: byDirectory[directory(of: path)] ?? [], .convention) }
        }
        return links.links
    }

    private static let names = ImportQuery(TreeSitterLanguage.go.tsLanguage, """
        (import_spec path: (_) @path)
        (source_file (function_declaration name: (identifier) @definition))
        (source_file (type_declaration (type_spec name: (type_identifier) @definition)))
        (source_file (const_declaration (const_spec name: (identifier) @definition)))
        (source_file (var_declaration (var_spec name: (identifier) @definition)))
        (identifier) @reference
        (type_identifier) @reference
        (interpreted_string_literal) @string
        (raw_string_literal) @string
        """)

    private func isGo(_ path: String) -> Bool {
        path.hasSuffix(".go")
    }

    private func isTest(_ path: String) -> Bool {
        path.hasSuffix("_test.go")
    }

    /// The import path of `directory`'s package, from the module nearest above it.
    private func importPath(of directory: String, modules: [String: String]) -> String? {
        for root in [directory] + ancestors(of: directory) {
            guard let module = modules[root] else { continue }
            let rest = root.isEmpty ? directory : String(directory.dropFirst(root.count + 1))
            return rest.isEmpty ? module : "\(module)/\(rest)"
        }
        return nil
    }

    /// The module path a `go.mod` declares.
    private func modulePath(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count >= 2, words[0] == "module" { return unquoted(String(words[1])) }
        }
        return nil
    }

    private func unquoted(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
    }
}
