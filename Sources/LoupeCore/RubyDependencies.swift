import CodeEditLanguages
import Foundation

/// Ruby's `require_relative` names a file from the requiring one. Rails and Zeitwerk code
/// requires nothing, loading a constant from the file its name gives (`Billing::LineItem` from
/// `…/billing/line_item.rb`), so a constant a file names uses the changed files whose paths end
/// that way, specs aside.
struct RubyDependencies: DependencyLanguage {
    func filesToRead(among paths: [String]) -> [String] {
        paths.filter(isRuby)
    }

    func dependencies(among paths: [String], contents: [String: String]) -> [String: Set<String>] {
        let sources = paths.filter { isRuby($0) && contents[$0] != nil }
        guard !sources.isEmpty else { return [:] }
        let changed = Set(paths)
        let loadable = sources.filter { !isSpec($0) }
        let parsed = concurrentMap(sources) { path in Self.names?.captures(in: contents[path] ?? "") ?? [] }
        var dependencies: [String: Set<String>] = [:]
        for (path, captures) in zip(sources, parsed) {
            var used = Set<String>()
            for capture in captures {
                switch capture.name {
                case "required":
                    let required = capture.text.hasSuffix(".rb") ? capture.text : capture.text + ".rb"
                    if let file = normalisedPath(joined(directory(of: path), required)), changed.contains(file) { used.insert(file) }
                case "constant":
                    let file = capture.text.components(separatedBy: "::").map(underscored).joined(separator: "/") + ".rb"
                    used.formUnion(loadable.filter { $0 == file || $0.hasSuffix("/" + file) })
                default: break
                }
            }
            used.remove(path)
            if !used.isEmpty { dependencies[path] = used }
        }
        return dependencies
    }

    private static let names = ImportQuery(TreeSitterLanguage.ruby.tsLanguage, """
        ((call method: (identifier) @method arguments: (argument_list . (string (string_content) @required))) (#eq? @method "require_relative"))
        (scope_resolution) @constant
        (constant) @constant
        """)

    private func isRuby(_ path: String) -> Bool {
        path.hasSuffix(".rb")
    }

    private func isSpec(_ path: String) -> Bool {
        path.hasSuffix("_spec.rb") || path.hasSuffix("_test.rb")
    }

    /// A constant's name as its file is named: `LineItem` as `line_item`, `HTTPClient` as
    /// `http_client`.
    private func underscored(_ name: String) -> String {
        let characters = Array(name.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        var result = ""
        for (index, character) in characters.enumerated() {
            if character.isUppercase, index > 0 {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) { result.append("_") }
            }
            result.append(contentsOf: character.lowercased())
        }
        return result
    }
}
