import Foundation

/// Terraform's references: a directory's `.tf` files are one module sharing one scope, so a file
/// uses the file in its directory that defines what it refers to (`var.x`, `local.x`,
/// `module.x`, `data.t.x`, `t.x`); and a `module` block whose source is a local path uses that
/// directory's changed files. Modules from a registry or git aren't changed files.
struct TerraformDependencies: DependencyLanguage {
    func filesToRead(among paths: [String]) -> [String] {
        paths.filter(isTerraform)
    }

    func dependencies(among paths: [String], contents: [String: String]) -> [String: Set<String>] {
        let sources = paths.filter { isTerraform($0) && contents[$0] != nil }
        guard !sources.isEmpty else { return [:] }
        var byDirectory: [String: [String]] = [:]
        // What each file defines, by directory, as it's referred to.
        var definers: [String: [String: Set<String>]] = [:]
        var references: [String: Set<String>] = [:]
        var calls: [String: Set<String>] = [:]
        for path in sources {
            guard let text = contents[path] else { continue }
            let module = directory(of: path)
            byDirectory[module, default: []].append(path)
            for name in definitions(in: text) { definers[module, default: [:]][name, default: []].insert(path) }
            references[path] = Self.referenceNames(in: text)
            calls[path] = Set(Self.localSources(in: text).compactMap { normalisedPath(joined(module, $0)) })
        }
        var dependencies: [String: Set<String>] = [:]
        for path in sources {
            let module = directory(of: path)
            var used = Set<String>()
            for name in references[path] ?? [] { used.formUnion(definers[module]?[name] ?? []) }
            for called in calls[path] ?? [] { used.formUnion(byDirectory[called] ?? []) }
            used.remove(path)
            if !used.isEmpty { dependencies[path] = used }
        }
        return dependencies
    }

    private static let blocks = ImportQuery(VendoredGrammar.hcl.tsLanguage, """
        (config_file (body (block (identifier) @kind . (string_lit (template_literal) @first) . (string_lit (template_literal) @second))))
        (config_file (body (block (identifier) @kind . (string_lit (template_literal) @first) . (block_start))))
        ((config_file (body (block (identifier) @kind (body (attribute (identifier) @local))))) (#eq? @kind "locals"))
        """)

    private static let references = ImportQuery(VendoredGrammar.hcl.tsLanguage, """
        (expression (variable_expr (identifier) @root) . (get_attr (identifier) @first))
        (expression (variable_expr (identifier) @root) . (get_attr (identifier) @first) . (get_attr (identifier) @second))
        """)

    private static let moduleSources = ImportQuery(VendoredGrammar.hcl.tsLanguage, """
        ((block (identifier) @kind (body (attribute (identifier) @attribute (expression (literal_value (string_lit (template_literal) @source))))))
          (#eq? @kind "module") (#eq? @attribute "source"))
        ((block (identifier) @kind (body (attribute (identifier) @attribute (expression (template_expr (quoted_template (template_literal) @source))))))
          (#eq? @kind "module") (#eq? @attribute "source"))
        """)

    private func isTerraform(_ path: String) -> Bool {
        path.hasSuffix(".tf") || path.hasSuffix(".tofu")
    }

    /// The names `text` defines, as other files in its module refer to them.
    private func definitions(in text: String) -> Set<String> {
        var names = Set<String>()
        for match in Self.blocks?.matches(in: text) ?? [] {
            let captures = Dictionary(match.map { ($0.name, $0.text) }) { first, _ in first }
            switch (captures["kind"], captures["first"], captures["second"], captures["local"]) {
            case let ("locals", _, _, local?): names.insert("local.\(local)")
            case let ("variable", name?, nil, _): names.insert("var.\(name)")
            case let ("module", name?, nil, _): names.insert("module.\(name)")
            case let ("data", type?, name?, _): names.insert("data.\(type).\(name)")
            case let ("resource", type?, name?, _), let ("ephemeral", type?, name?, _): names.insert("\(type).\(name)")
            default: break
            }
        }
        return names
    }

    /// The names `text` refers to, in the form `definitions` gives them.
    private static func referenceNames(in text: String) -> Set<String> {
        var names = Set<String>()
        for match in references?.matches(in: text) ?? [] {
            let captures = Dictionary(match.map { ($0.name, $0.text) }) { first, _ in first }
            guard let root = captures["root"], let first = captures["first"] else { continue }
            switch root {
            case "var", "local", "module": names.insert("\(root).\(first)")
            case "data": if let second = captures["second"] { names.insert("data.\(first).\(second)") }
            case "count", "each", "path", "self", "terraform": break
            default: names.insert("\(root).\(first)")
            }
        }
        return names
    }

    /// The local paths `text`'s module blocks take their source from, relative to its directory.
    private static func localSources(in text: String) -> [String] {
        (moduleSources?.captures(in: text) ?? []).compactMap { capture in
            guard capture.name == "source", capture.text.hasPrefix("./") || capture.text.hasPrefix("../") else { return nil }
            return capture.text
        }
    }
}
