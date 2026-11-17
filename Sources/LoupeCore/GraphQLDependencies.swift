import Foundation
import LoupeModel
import TreeSitterGraphQL

/// GraphQL schemas, split across files as servers merge them: a schema or query uses the
/// changed files defining the types it names. A schema is the interface of the code beside it
/// named for it, such as `x.resolvers.ts` or gqlgen's `x.resolvers.go` beside `x.graphql`.
struct GraphQLDependencies: DependencyRule {
    func filesToRead(among paths: [String]) -> [String] {
        paths.filter(isGraphQL)
    }

    func links(among paths: [String], contents: [String: String]) -> [DependencyLink] {
        let schemas = paths.filter(isGraphQL)
        guard !schemas.isEmpty else { return [] }
        let read = schemas.filter { contents[$0] != nil }
        let parsed = Dictionary(uniqueKeysWithValues: zip(read, concurrentMap(read) { path in
            Self.query?.captures(in: contents[path] ?? "") ?? []
        }))
        var definitions = NameIndex()
        for (path, captures) in parsed {
            for capture in captures where capture.name == "definition" { definitions.define(capture.text, in: path, scope: "") }
        }
        var links = LinkCollector()
        for (path, captures) in parsed {
            for capture in captures where capture.name == "reference" {
                links.add(from: path, to: definitions.definers(of: capture.text, in: ""), .names)
            }
        }
        let byDirectory = Dictionary(grouping: paths.filter { !isGraphQL($0) }, by: directory(of:))
        for schema in schemas {
            let stem = name(of: schema)
            for path in byDirectory[directory(of: schema)] ?? [] where name(of: path) == stem {
                links.add(from: path, to: [schema], .interface)
            }
        }
        return links.links
    }

    private static let query = ImportQuery(tree_sitter_graphql(), """
        (object_type_definition (name) @definition)
        (interface_type_definition (name) @definition)
        (union_type_definition (name) @definition)
        (enum_type_definition (name) @definition)
        (input_object_type_definition (name) @definition)
        (scalar_type_definition (name) @definition)
        (object_type_extension (name) @reference)
        (interface_type_extension (name) @reference)
        (union_type_extension (name) @reference)
        (enum_type_extension (name) @reference)
        (input_object_type_extension (name) @reference)
        (named_type (name) @reference)
        """)

    /// A file's name up to its first dot, which names what it's for.
    private func name(of path: String) -> String {
        String((path as NSString).lastPathComponent.prefix { $0 != "." })
    }
}

func isGraphQL(_ path: String) -> Bool {
    [".graphql", ".gql", ".graphqls"].contains { path.hasSuffix($0) }
}

/// A file declaring an interface other code is written against.
func isSchema(_ path: String) -> Bool {
    isProto(path) || isGraphQL(path)
}
