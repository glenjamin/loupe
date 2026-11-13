import Foundation
import LoupeModel
import TreeSitterProto

/// Protocol Buffers' imports: a `.proto` file uses the protos it imports, named from wherever
/// the compiler is told to look, so by the end of their path, the one beside it first.
struct ProtoDependencies: DependencyRule {
    func filesToRead(among paths: [String]) -> [String] {
        paths.filter(isProto)
    }

    func links(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        let protos = paths.filter { isProto($0) && contents[$0] != nil }
        guard !protos.isEmpty else { return [] }
        let imports = concurrentMap(protos) { path in
            ProtoFile.query?.captures(in: contents[path] ?? "").filter { $0.name == "import" }.map { unquoted($0.text) } ?? []
        }
        var links = LinkCollector()
        for (path, imported) in zip(protos, imports) {
            for name in imported {
                links.add(from: path, to: importedProtos(name, from: path, among: protos), .imports)
            }
        }
        return links.links
    }

    private func importedProtos(_ name: String, from path: String, among protos: [String]) -> [String] {
        let beside = joined(directory(of: path), name)
        if protos.contains(beside) { return [beside] }
        return protos.filter { $0 == name || $0.hasSuffix("/\(name)") }
    }
}

/// What Go's rule needs of a `.proto` file: the Go package its generated code goes in.
enum ProtoFile {
    /// The import path `option go_package` names, when it names a full one rather than a path
    /// relative to where the code is generated.
    static func goPackage(in text: String) -> String? {
        guard let value = query?.captures(in: text).first(where: { $0.name == "go_package" }).map({ unquoted($0.text) }) else { return nil }
        // `path;name` names the package as well as its path.
        let path = String(value.split(separator: ";", omittingEmptySubsequences: false)[0])
        return path.contains("/") && !path.hasPrefix(".") ? path : nil
    }

    static let query = ImportQuery(tree_sitter_proto(), """
        (import path: (string) @import)
        (option (identifier) @option (constant (string) @go_package) (#eq? @option "go_package"))
        """)
}

func isProto(_ path: String) -> Bool {
    path.hasSuffix(".proto")
}

private func unquoted(_ text: String) -> String {
    text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
}
