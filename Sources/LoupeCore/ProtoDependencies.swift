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

/// The changed protos code generated from them is imported by, for scripts, whose generators
/// name it after the proto or the types it declares: `x_pb`, `x_grpc_pb` or `x_connect`
/// anywhere (protoc's and protobuf-es's), `dir/x` beside a proto at `…/dir/x.proto` (ts-proto's
/// and others mirroring the protos' tree), or `package/path/Type` for a top-level type
/// (`@grpc/proto-loader`'s).
struct GeneratedProtos {
    private let protos: [(path: String, stem: String, parent: String, package: [String], types: Set<String>)]

    init(among paths: [String], contents: [String: String]) {
        protos = paths.filter(isProto).compactMap { path in
            guard let text = contents[path] else { return nil }
            let captures = ProtoFile.query?.captures(in: text) ?? []
            let package = captures.first { $0.name == "package" }.map { $0.text.split(separator: ".").map { normalised(String($0)) } } ?? []
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return (path, normalised(name), normalised((directory(of: path) as NSString).lastPathComponent), package, Set(captures.filter { $0.name == "type" }.map(\.text)))
        }
    }

    /// The protos the module at `path`, without resolving its extension, is generated from.
    func protos(generating path: String) -> [String] {
        guard !protos.isEmpty else { return [] }
        var parts = path.split(separator: "/").map(String.init)
        guard var last = parts.popLast() else { return [] }
        let scriptExtensions = [".js", ".ts", ".mjs", ".cjs", ".jsx", ".tsx"]
        if let ext = scriptExtensions.first(where: last.hasSuffix) { last.removeLast(ext.count) }
        let directories = parts.map(normalised)
        var name = normalised(last)
        let suffix = ["_grpc_web_pb", "_grpc_pb", "_pb", "_connect"].first(where: name.hasSuffix)
        if let suffix { name.removeLast(suffix.count) }
        return protos.filter { proto in
            if name == proto.stem, suffix != nil || directories.last == proto.parent { return true }
            return !proto.package.isEmpty && proto.types.contains(last) && directories.suffix(proto.package.count) == proto.package[...]
        }.map(\.path)
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
        (package (full_ident) @package)
        (source_file (message (message_name) @type))
        (source_file (enum (enum_name) @type))
        (source_file (service (service_name) @type))
        """)
}

func isProto(_ path: String) -> Bool {
    path.hasSuffix(".proto")
}

/// A name as generators may spell it, in either case and with `-` or `_`.
private func normalised(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: "-", with: "_")
}

private func unquoted(_ text: String) -> String {
    text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
}
