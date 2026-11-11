import Foundation
import LoupeModel

/// Terraform's references: a directory's `.tf` files are one module sharing one scope, so a file
/// uses the file in its directory that defines what it refers to (`var.x`, `local.x`,
/// `module.x`, `data.t.x`, `t.x`); and a `module` block whose source is a local path uses that
/// directory's changed files. Modules from a registry or git aren't changed files. A small
/// module's changed files are read as one, so they're grouped even where neither uses the other;
/// a large one, as a root configuration gathering many services often is, holds unrelated files.
struct TerraformDependencies: DependencyRule {
    /// The most `.tf` files a module can have and still be read as one.
    static let smallModule = 12

    func filesToRead(among paths: [String]) -> [String] {
        paths.filter(isTerraform)
    }

    func directoriesToList(among paths: [String]) -> [String] {
        Array(Set(paths.filter(isTerraform).map(directory(of:)))).sorted()
    }

    func links(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        links(among: paths, contents: contents, listings: [:])
    }

    func links(among paths: [String], contents: [String: String], listings: [String: [String]]) -> [DependencyLink] {
        var links = references(among: paths, contents: contents)
        let changed = Dictionary(grouping: paths.filter(isTerraform), by: directory(of:))
        for (module, files) in changed where files.count > 1 {
            guard let listed = listings[module], listed.filter(isTerraform).count <= Self.smallModule else { continue }
            let files = files.sorted()
            for (index, file) in files.enumerated() {
                for other in files[(index + 1)...] { links.append(DependencyLink(from: file, to: other, reason: .module)) }
            }
        }
        return links
    }

    private func references(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        let sources = paths.filter { isTerraform($0) && contents[$0] != nil }
        guard !sources.isEmpty else { return [] }
        let parsed = concurrentMap(sources) { path in Self.query?.matches(in: contents[path] ?? "") ?? [] }
        var byDirectory: [String: [String]] = [:]
        // What each module's files define, as it's referred to.
        var definitions = NameIndex()
        var references: [String: Set<String>] = [:]
        var calls: [String: Set<String>] = [:]
        for (path, matches) in zip(sources, parsed) {
            let module = directory(of: path)
            byDirectory[module, default: []].append(path)
            for match in matches {
                let captures = Dictionary(match.map { ($0.name, $0.text) }) { first, _ in first }
                if let source = captures["source"] {
                    if source.hasPrefix("./") || source.hasPrefix("../"), let called = normalisedPath(joined(module, source)) { calls[path, default: []].insert(called) }
                } else if let root = captures["root"] {
                    if let name = referenceName(root: root, captures) { references[path, default: []].insert(name) }
                } else if let name = definitionName(captures) {
                    definitions.define(name, in: path, scope: module)
                }
            }
        }
        var links = LinkCollector()
        for path in sources {
            let module = directory(of: path)
            for name in references[path] ?? [] { links.add(from: path, to: definitions.definers(of: name, in: module), .names) }
            for called in calls[path] ?? [] { links.add(from: path, to: byDirectory[called] ?? [], .imports) }
        }
        return links.links
    }

    /// Top-level blocks and locals, which define names; references to them; and local module sources.
    private static let query = ImportQuery(VendoredGrammar.hcl.tsLanguage, """
        (config_file (body (block (identifier) @kind . (string_lit (template_literal) @first) . (string_lit (template_literal) @second))))
        (config_file (body (block (identifier) @kind . (string_lit (template_literal) @first) . (block_start))))
        ((config_file (body (block (identifier) @kind (body (attribute (identifier) @local))))) (#eq? @kind "locals"))
        (expression (variable_expr (identifier) @root) . (get_attr (identifier) @attribute))
        (expression (variable_expr (identifier) @root) . (get_attr (identifier) @attribute) . (get_attr (identifier) @attribute2))
        ((block (identifier) @call (body (attribute (identifier) @argument (expression (literal_value (string_lit (template_literal) @source))))))
          (#eq? @call "module") (#eq? @argument "source"))
        ((block (identifier) @call (body (attribute (identifier) @argument (expression (template_expr (quoted_template (template_literal) @source))))))
          (#eq? @call "module") (#eq? @argument "source"))
        """)

    /// The name a block or local defines, as other files in its module refer to it.
    private func definitionName(_ captures: [String: String]) -> String? {
        switch (captures["kind"], captures["first"], captures["second"], captures["local"]) {
        case let ("locals", _, _, local?): "local.\(local)"
        case let ("variable", name?, nil, _): "var.\(name)"
        case let ("module", name?, nil, _): "module.\(name)"
        case let ("data", type?, name?, _): "data.\(type).\(name)"
        case let ("resource", type?, name?, _), let ("ephemeral", type?, name?, _): "\(type).\(name)"
        default: nil
        }
    }

    /// A reference's name, in the form `definitionName` gives it.
    private func referenceName(root: String, _ captures: [String: String]) -> String? {
        guard let first = captures["attribute"] else { return nil }
        switch root {
        case "var", "local", "module": return "\(root).\(first)"
        case "data": return captures["attribute2"].map { "data.\(first).\($0)" }
        case "count", "each", "path", "self", "terraform": return nil
        default: return "\(root).\(first)"
        }
    }

    private func isTerraform(_ path: String) -> Bool {
        path.hasSuffix(".tf") || path.hasSuffix(".tofu")
    }
}
