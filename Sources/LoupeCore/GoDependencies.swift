import CodeEditLanguages
import Foundation

/// Go's imports: an import path names a package, a directory under the module whose `go.mod`
/// is nearest above the file, so a file uses that package's changed files. Within a package,
/// with no imports between its files, a file uses those defining the top-level names it
/// refers to. Its tests use their own directory's other files, whichever package they're in.
struct GoDependencies: DependencyLanguage {
    func filesToRead(among paths: [String]) -> [String] {
        let sources = paths.filter(isGo)
        var modules: [String] = []
        var seen = Set<String>()
        for path in sources {
            for directory in ancestors(of: path) where seen.insert(directory).inserted { modules.append(joined(directory, "go.mod")) }
        }
        return sources + modules
    }

    func dependencies(among paths: [String], contents: [String: String]) -> [String: Set<String>] {
        let sources = paths.filter { isGo($0) && contents[$0] != nil }
        guard !sources.isEmpty else { return [:] }
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
        let parsed = Dictionary(uniqueKeysWithValues: zip(sources, concurrentMap(sources) { path in
            Self.names?.captures(in: contents[path] ?? "") ?? []
        }))
        // What each directory's files define at the top level, by name.
        var definers: [String: [String: Set<String>]] = [:]
        for path in sources where !isTest(path) {
            for capture in parsed[path] ?? [] where capture.name == "definition" && !["_", "init", "main"].contains(capture.text) {
                definers[directory(of: path), default: [:]][capture.text, default: []].insert(path)
            }
        }
        var dependencies: [String: Set<String>] = [:]
        for path in sources {
            var used = Set<String>()
            for capture in parsed[path] ?? [] {
                switch capture.name {
                case "path": used.formUnion(packages[unquoted(capture.text)] ?? [])
                case "reference": used.formUnion(definers[directory(of: path)]?[capture.text] ?? [])
                default: break
                }
            }
            if isTest(path) { used.formUnion(byDirectory[directory(of: path)] ?? []) }
            used.remove(path)
            if !used.isEmpty { dependencies[path] = used }
        }
        return dependencies
    }

    private static let names = ImportQuery(TreeSitterLanguage.go.tsLanguage, """
        (import_spec path: (_) @path)
        (source_file (function_declaration name: (identifier) @definition))
        (source_file (type_declaration (type_spec name: (type_identifier) @definition)))
        (source_file (const_declaration (const_spec name: (identifier) @definition)))
        (source_file (var_declaration (var_spec name: (identifier) @definition)))
        (identifier) @reference
        (type_identifier) @reference
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
