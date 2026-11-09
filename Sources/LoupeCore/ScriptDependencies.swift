import CodeEditLanguages
import Foundation
import LoupeModel

/// JavaScript's and TypeScript's imports, requires and re-exports: a relative specifier is a
/// path from the importing file, and a bare one may be mapped to paths by the `paths` and
/// `baseUrl` of the `tsconfig.json` or `jsconfig.json` nearest above it. A path names a file
/// with or without its extension, or a directory's `index`, as bundlers and TypeScript resolve.
/// Packages from npm aren't changed files, so they're passed over. A type declaration file
/// (`x.d.ts`) names the script it declares (`x.js`) too, when that's changed. Any other
/// string naming a changed file, such as a fixture's path, uses it.
struct ScriptDependencies: DependencyRule {
    func filesToRead(among paths: [String]) -> [String] {
        let sources = paths.filter { Self.grammar(of: $0) != nil }
        var configs: [String] = []
        var seen = Set<String>()
        for path in sources {
            for directory in ancestors(of: path) where seen.insert(directory).inserted {
                configs += Self.configNames.map { joined(directory, $0) }
            }
        }
        return sources + configs
    }

    func links(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        let changed = Set(paths.filter { contents[$0] != nil || Self.grammar(of: $0) == nil })
        let named = Set(paths)
        var configs: [String: Config] = [:]
        for (path, text) in contents where Self.configNames.contains((path as NSString).lastPathComponent) {
            if let config = Config(text, at: directory(of: path)) { configs[directory(of: path)] = config }
        }
        let scripts = paths.filter { Self.grammar(of: $0) != nil && contents[$0] != nil }
        let parsed = Dictionary(uniqueKeysWithValues: zip(scripts, concurrentMap(scripts) { path in
            Self.grammar(of: path)?.captures(in: contents[path] ?? "") ?? []
        }))
        var links = LinkCollector()
        for path in scripts {
            let config = ([directory(of: path)] + ancestors(of: path)).lazy.compactMap { configs[$0] }.first
            for capture in parsed[path] ?? [] {
                guard capture.name == "source" else {
                    links.add(from: path, to: filesNamed(by: capture.text, from: path, among: named), .path)
                    continue
                }
                let specifier = capture.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                for base in bases(of: specifier, from: path, config: config) {
                    let files = resolve(base, among: changed)
                    if !files.isEmpty {
                        links.add(from: path, to: files, .imports)
                        break
                    }
                }
            }
        }
        return links.links
    }

    private static let configNames = ["tsconfig.json", "jsconfig.json"]

    private static let javascript = ImportQuery(TreeSitterLanguage.javascript.tsLanguage, queries)
    private static let typescript = ImportQuery(TreeSitterLanguage.typescript.tsLanguage, queries)
    private static let tsx = ImportQuery(TreeSitterLanguage.tsx.tsLanguage, queries)

    private static let queries = """
        (import_statement source: (string) @source)
        (export_statement source: (string) @source)
        ((call_expression function: (identifier) @function arguments: (arguments . (string) @source)) (#eq? @function "require"))
        (call_expression function: (import) arguments: (arguments . (string) @source))
        (string (string_fragment) @string)
        """

    private static func grammar(of path: String) -> ImportQuery? {
        switch (path as NSString).pathExtension.lowercased() {
        case "ts", "mts", "cts": typescript
        case "tsx": tsx
        case "js", "jsx", "mjs", "cjs": javascript
        default: nil
        }
    }

    /// The paths, without resolving extensions, that `specifier` may name from `path`.
    private func bases(of specifier: String, from path: String, config: Config?) -> [String] {
        if specifier.hasPrefix("./") || specifier.hasPrefix("../") || specifier == "." || specifier == ".." {
            return [normalisedPath(joined(directory(of: path), specifier))].compactMap { $0 }
        }
        guard let config else { return [] }
        return config.bases(of: specifier).compactMap(normalisedPath)
    }

    /// The changed file `base` names: itself, with a script's extension, or its directory's
    /// index; a declaration file with the script it declares.
    private func resolve(_ base: String, among changed: Set<String>) -> [String] {
        if changed.contains(base) { return [base] }
        let extensions = ["ts", "tsx", "d.ts", "js", "jsx", "mjs", "cjs", "mts", "cts"]
        var candidates = extensions.map { "\(base).\($0)" } + extensions.map { "\(base)/index.\($0)" }
        // TypeScript's ES modules import a file by the name it compiles to.
        let compiled = ["js": ["ts", "tsx"], "jsx": ["tsx"], "mjs": ["mts"], "cjs": ["cts"]]
        let ext = (base as NSString).pathExtension
        if let sources = compiled[ext] {
            let stem = (base as NSString).deletingPathExtension
            candidates = sources.map { "\(stem).\($0)" } + candidates
        }
        guard let found = candidates.first(where: changed.contains) else { return [] }
        guard found.hasSuffix(".d.ts") else { return [found] }
        let stem = String(found.dropLast(".d.ts".count))
        return [found] + ["js", "jsx", "mjs", "cjs"].map { "\(stem).\($0)" }.filter(changed.contains)
    }
}

/// What a `tsconfig.json` says about resolving bare specifiers.
private struct Config {
    /// Where `paths` and a bare specifier resolve from.
    let base: String
    let hasBaseUrl: Bool
    /// Each pattern, with at most one `*`, and the paths it maps to, in the file's order.
    let paths: [(pattern: String, targets: [String])]

    init?(_ text: String, at directory: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(lenientJSON(text).utf8)) as? [String: Any],
              let options = object["compilerOptions"] as? [String: Any]
        else { return nil }
        let baseUrl = options["baseUrl"] as? String
        hasBaseUrl = baseUrl != nil
        base = joined(directory, baseUrl ?? ".")
        let paths = options["paths"] as? [String: [String]] ?? [:]
        // The longest prefix before the `*` wins, as TypeScript picks.
        self.paths = paths.map { ($0.key, $0.value) }.sorted { $0.pattern.count > $1.pattern.count }
        guard hasBaseUrl || !self.paths.isEmpty else { return nil }
    }

    func bases(of specifier: String) -> [String] {
        for (pattern, targets) in paths {
            if let star = pattern.firstIndex(of: "*") {
                let prefix = pattern[..<star]
                let suffix = pattern[pattern.index(after: star)...]
                guard specifier.hasPrefix(prefix), specifier.hasSuffix(suffix), specifier.count >= prefix.count + suffix.count else { continue }
                let matched = specifier.dropFirst(prefix.count).dropLast(suffix.count)
                return targets.map { joined(base, $0.replacingOccurrences(of: "*", with: matched)) }
            } else if pattern == specifier {
                return targets.map { joined(base, $0) }
            }
        }
        return hasBaseUrl ? [joined(base, specifier)] : []
    }
}

/// JSON with the comments and trailing commas `tsconfig.json` allows taken out.
private func lenientJSON(_ text: String) -> String {
    // Comments first, so a comma before one closing a list is seen as trailing.
    let uncommented = outsideStrings(text) { character, rest, output in
        if character == "/", rest.first == "/" {
            while let next = rest.first, next != "\n" { rest.removeFirst() }
        } else if character == "/", rest.first == "*" {
            rest.removeFirst()
            while let next = rest.popFirst(), !(next == "*" && rest.first == "/") {}
            _ = rest.popFirst()
        } else {
            output.append(character)
        }
    }
    return outsideStrings(uncommented) { character, rest, output in
        let next = rest.first { !$0.isWhitespace }
        if character != "," || (next != "}" && next != "]") { output.append(character) }
    }
}

/// `text` with each character outside its strings handed to `handle`, which appends what it
/// keeps and may take more from the rest; strings are kept whole.
private func outsideStrings(_ text: String, _ handle: (Character, inout ArraySlice<Character>, inout String) -> Void) -> String {
    var output = ""
    var rest = Array(text)[...]
    var inString = false
    while let character = rest.popFirst() {
        if inString {
            output.append(character)
            if character == "\\", let escaped = rest.popFirst() {
                output.append(escaped)
            } else if character == "\"" {
                inString = false
            }
        } else if character == "\"" {
            inString = true
            output.append(character)
        } else {
            handle(character, &rest, &output)
        }
    }
    return output
}
