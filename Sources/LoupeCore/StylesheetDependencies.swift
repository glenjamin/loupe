import Foundation

/// SCSS's `@use`, `@forward` and `@import`: a path from the importing file names a stylesheet
/// as written, as a partial (`_name.scss`), or as a directory's `_index.scss`. Built-in modules
/// (`sass:math`) and paths found through load paths, such as `node_modules`, aren't followed.
struct StylesheetDependencies: DependencyLanguage {
    func filesToRead(among paths: [String]) -> [String] {
        paths.filter(isSCSS)
    }

    func dependencies(among paths: [String], contents: [String: String]) -> [String: Set<String>] {
        let changed = Set(paths)
        let sources = paths.filter { isSCSS($0) && contents[$0] != nil }
        let parsed = concurrentMap(sources) { path in Self.imports?.captures(in: contents[path] ?? "") ?? [] }
        var dependencies: [String: Set<String>] = [:]
        for (path, captures) in zip(sources, parsed) {
            var used = Set<String>()
            for capture in captures where capture.name == "source" {
                let specifier = capture.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !specifier.contains(":"), let base = normalisedPath(joined(directory(of: path), specifier)) else { continue }
                if let file = candidates(of: base).first(where: changed.contains) { used.insert(file) }
            }
            used.remove(path)
            if !used.isEmpty { dependencies[path] = used }
        }
        return dependencies
    }

    private static let imports = ImportQuery(VendoredGrammar.scss.tsLanguage, """
        (use_statement (string) @source)
        (forward_statement (string) @source)
        (_ "@import" (string) @source)
        """)

    private func isSCSS(_ path: String) -> Bool {
        path.hasSuffix(".scss")
    }

    /// The files `base` may name, in the order Sass tries them.
    private func candidates(of base: String) -> [String] {
        let name = (base as NSString).lastPathComponent
        let folder = directory(of: base)
        if ["scss", "css", "sass"].contains((base as NSString).pathExtension) { return [base, joined(folder, "_" + name)] }
        return ["scss", "css"].flatMap { [joined(folder, "_\(name).\($0)"), "\(base).\($0)"] }
            + ["scss", "css"].flatMap { [joined(base, "_index.\($0)"), joined(base, "index.\($0)")] }
    }
}
