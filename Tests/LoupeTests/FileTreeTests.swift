import LoupeModel
import Testing

struct FileTreeTests {
    @Test func nestsFilesUnderTheirDirectoriesWithDirectoriesFirstThenFilesEachAlphabetically() {
        let tree = FileTree(paths: ["README.md", "src/main.go", "src/api/server.go", "Makefile", "src/Zeta.go", "docs/guide.md", "src/api/client.go"])
        #expect(outline(tree) == [
            "docs/",
            "  guide.md",
            "src/",
            "  api/",
            "    client.go",
            "    server.go",
            "  main.go",
            "  Zeta.go",
            "Makefile",
            "README.md",
        ])
        #expect(tree.files == ["docs/guide.md", "src/api/client.go", "src/api/server.go", "src/main.go", "src/Zeta.go", "Makefile", "README.md"])
    }

    @Test func foldsARunOfDirectoriesEachHoldingOnlyOneDirectoryIntoOneNode() {
        let tree = FileTree(paths: [
            "client/src/components/dashboard/Dashboard.tsx",
            "client/src/components/dataset/Dataset.tsx",
            "client/src/generated/graphql/types.ts",
            "server/main.go",
        ])
        #expect(outline(tree) == [
            "client/src/",
            "  components/",
            "    dashboard/",
            "      Dashboard.tsx",
            "    dataset/",
            "      Dataset.tsx",
            "  generated/graphql/",
            "    types.ts",
            "server/",
            "  main.go",
        ])
        guard case let .directory(generated)? = tree.nodes.first?.children?.last else { Issue.record("expected a directory"); return }
        #expect(generated.path == "client/src/generated/graphql", "a folded node stands for its deepest directory")
    }

    @Test func keepsADirectoryHoldingOneFileAsItsOwnNode() {
        #expect(outline(FileTree(paths: ["a/b/c.txt"])) == ["a/b/", "  c.txt"])
        #expect(outline(FileTree(paths: ["a/b/c.txt", "a/d.txt"])) == ["a/", "  b/", "    c.txt", "  d.txt"])
    }

    @Test func listsFilesAtTheRootOnTheirOwn() {
        let tree = FileTree(paths: ["go.mod", "go.sum"])
        #expect(outline(tree) == ["go.mod", "go.sum"])
        #expect(tree.files == ["go.mod", "go.sum"])
    }

    @Test func ordersNumbersByValue() {
        #expect(FileTree(paths: ["v10.sql", "v9.sql", "v1.sql"]).files == ["v1.sql", "v9.sql", "v10.sql"])
    }

    @Test func keepsAFileAndADirectoryOfTheSameNameApart() {
        let tree = FileTree(paths: ["lib", "lib/x.go"])
        #expect(outline(tree) == ["lib/", "  x.go", "lib"])
        #expect(Set(tree.nodes.map(\.id)).count == 2)
    }
}

/// The tree as indented lines, directories ending in a slash.
private func outline(_ tree: FileTree) -> [String] {
    func lines(_ nodes: [FileTree.Node], depth: Int) -> [String] {
        nodes.flatMap { node in
            let indent = String(repeating: "  ", count: depth)
            guard let children = node.children else { return [indent + node.name] }
            return [indent + node.name + "/"] + lines(children, depth: depth + 1)
        }
    }
    return lines(tree.nodes, depth: 0)
}
