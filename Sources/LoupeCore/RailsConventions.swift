import CodeEditLanguages
import Foundation
import LoupeModel

/// Rails' conventions, which tie files no import does: a view uses the helper methods it calls
/// from changed `app/helpers` files, and the partials it renders; a controller uses its views
/// (`app/controllers/orders_controller.rb` those in `app/views/orders`), as its actions render
/// them, so top down reads routes, controller, then views; the routes use the controllers they
/// name; and a spec or helper uses the helper methods it calls.
struct RailsConventions: DependencyRule {
    func filesToRead(among paths: [String]) -> [String] {
        paths.filter { isView($0) || isHelper($0) || isRoutes($0) || (isRuby($0) && isSpec($0)) }
    }

    func links(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        let changed = Set(paths)
        let readable = paths.filter { contents[$0] != nil }
        let parsed = Dictionary(uniqueKeysWithValues: zip(readable, concurrentMap(readable) { path in
            guard let text = contents[path] else { return [(name: String, text: String)]() }
            if isView(path) { return Self.code?.captures(in: rubyCode(ofTemplate: text)) ?? [] }
            if isHelper(path) || isSpec(path) { return Self.code?.captures(in: text) ?? [] }
            return []
        }))
        // The helper methods changed helper files define, which every view can call.
        var helpers = NameIndex()
        for path in readable where isHelper(path) {
            for capture in parsed[path] ?? [] where capture.name == "definition" { helpers.define(capture.text, in: path, scope: "") }
        }
        let controllers = paths.filter(isController)
        var links = LinkCollector()
        for path in readable {
            if isRoutes(path), let text = contents[path] {
                links.add(from: path, to: routedControllers(in: text).flatMap { controller(named: $0, among: controllers) }, .convention)
                continue
            }
            for capture in parsed[path] ?? [] {
                switch capture.name {
                case "reference": links.add(from: path, to: helpers.definers(of: capture.text, in: ""), .names)
                case "partial" where isView(path): links.add(from: path, to: partials(named: capture.text, from: path, among: changed), .imports)
                default: break
                }
            }
        }
        // A controller renders its views, deleted ones too, whose text isn't read.
        for view in paths where isView(view) {
            guard let folder = viewFolder(of: view) else { continue }
            for controller in controllers where controller == "app/controllers/\(folder)_controller.rb" {
                links.add(from: controller, to: [view], .convention)
            }
        }
        return links.links
    }

    /// Helper method definitions, the names a file calls, and the partials a template renders.
    private static let code = ImportQuery(TreeSitterLanguage.ruby.tsLanguage, """
        (method name: (identifier) @definition)
        (identifier) @reference
        (call method: (identifier) @reference)
        ((call method: (identifier) @render arguments: (argument_list . (string (string_content) @partial))) (#eq? @render "render"))
        ((pair key: (hash_key_symbol) @key value: (string (string_content) @partial)) (#eq? @key "partial"))
        """)

    private func isRuby(_ path: String) -> Bool { path.hasSuffix(".rb") }
    private func isView(_ path: String) -> Bool { path.hasSuffix(".erb") }
    private func isHelper(_ path: String) -> Bool { path.hasPrefix("app/helpers/") && isRuby(path) }
    private func isController(_ path: String) -> Bool { path.hasPrefix("app/controllers/") && path.hasSuffix("_controller.rb") }
    private func isRoutes(_ path: String) -> Bool { path == "config/routes.rb" || (path.hasPrefix("config/routes/") && isRuby(path)) }
    private func isSpec(_ path: String) -> Bool { path.hasSuffix("_spec.rb") || path.hasSuffix("_test.rb") }

    /// The folder under `app/views` a view is in, as its controller is named.
    private func viewFolder(of view: String) -> String? {
        guard view.hasPrefix("app/views/") else { return nil }
        let folder = directory(of: String(view.dropFirst("app/views/".count)))
        return folder.isEmpty ? nil : folder
    }

    /// The changed partials `name` renders: `shared/x` from `app/views`, `x` beside the view.
    private func partials(named name: String, from view: String, among changed: Set<String>) -> [String] {
        let folder = name.contains("/") ? joined("app/views", directory(of: name)) : directory(of: view)
        let prefix = joined(folder, "_" + (name as NSString).lastPathComponent + ".")
        return changed.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
    }

    /// The controllers routes name: `'orders#show'`, `to: 'orders#show'`, `controller: 'orders'`
    /// and `resources :orders`, each as its path under `app/controllers` without `_controller`.
    private func routedControllers(in text: String) -> [String] {
        let patterns = [#"['"]([a-z0-9_/]+)#[a-z0-9_]+['"]"#, #"controller:\s*['"]([a-z0-9_/]+)['"]"#, #"resources\s+:([a-z0-9_]+)"#]
        var names: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let string = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                names.append(string.substring(with: match.range(at: 1)))
            }
        }
        return names
    }

    /// The changed controller a route names, inside whatever namespace the routes put it.
    private func controller(named name: String, among controllers: [String]) -> [String] {
        let file = "\(name)_controller.rb"
        return controllers.filter { $0 == "app/controllers/\(file)" || $0.hasSuffix("/\(file)") }
    }
}

/// The Ruby inside an ERB template's tags, each on its own line, comments left out, so it parses
/// as one program: `<% if x %>…<% end %>` reads as `if x` then `end`.
func rubyCode(ofTemplate text: String) -> String {
    var code: [Substring] = []
    var rest = text[...]
    while let open = rest.range(of: "<%") {
        rest = rest[open.upperBound...]
        guard let close = rest.range(of: "%>") else { break }
        var tag = rest[..<close.lowerBound]
        rest = rest[close.upperBound...]
        if tag.hasPrefix("#") { continue }
        tag = tag.drop { $0 == "=" || $0 == "-" }
        if tag.hasSuffix("-") { tag = tag.dropLast() }
        code.append(tag)
    }
    return code.joined(separator: "\n")
}
