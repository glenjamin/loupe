import LoupeCore
import LoupeModel
import Testing

struct FileGraphTests {
    @Test func listsEachFileBeforeWhatItUsesTopDownAndAfterItBottomUp() {
        let graph = namedGraph(["api/server.go", "model/user.go", "store/users.go"], [
            "api/server.go": ["store/users.go"],
            "store/users.go": ["model/user.go"],
        ])
        #expect(outline(graph, .topDown) == ["group", "  api/server.go", "  store/users.go", "  model/user.go"])
        #expect(outline(graph, .bottomUp) == ["group", "  model/user.go", "  store/users.go", "  api/server.go"])
    }

    @Test func groupsFilesJoinedByUseLargestFirstWithTheStandaloneFilesLast() {
        let graph = namedGraph(["a/one.go", "a/two.go", "b/one.ts", "b/two.ts", "b/three.ts", "README.md", "Makefile"], [
            "a/two.go": ["a/one.go"],
            "b/one.ts": ["b/two.ts"],
            "b/three.ts": ["b/two.ts"],
        ])
        #expect(outline(graph, .bottomUp) == [
            "group",
            "  b/two.ts",
            "  b/one.ts",
            "  b/three.ts",
            "group",
            "  a/one.go",
            "  a/two.go",
            "group",
            "  Makefile",
            "  README.md",
        ], "a README joins the files beside it")
    }

    @Test func breaksTiesByTheTreesOrderSoBottomUpIsntTopDownReversed() {
        let graph = namedGraph(["core.go", "x.go", "y.go"], ["x.go": ["core.go"], "y.go": ["core.go"]])
        #expect(graph.ordered(.topDown) == ["x.go", "y.go", "core.go"])
        #expect(graph.ordered(.bottomUp) == ["core.go", "x.go", "y.go"])
    }

    @Test func takesFilesUsingEachOtherInACycleTogetherInTheTreesOrder() {
        let graph = namedGraph(["main.go", "b.go", "a.go", "base.go"], [
            "main.go": ["a.go"],
            "a.go": ["b.go"],
            "b.go": ["a.go", "base.go"],
        ])
        #expect(graph.ordered(.topDown) == ["main.go", "a.go", "b.go", "base.go"])
        #expect(graph.ordered(.bottomUp) == ["base.go", "a.go", "b.go", "main.go"])
    }

    @Test func withNoDependenciesListsAsTheTreeDoes() {
        let paths = ["src/b.go", "src/a/c.go", "README.md"]
        let graph = namedGraph(paths, [:])
        #expect(graph.ordered(.topDown) == FileTree(paths: paths).files)
        #expect(graph.ordered(.bottomUp) == FileTree(paths: paths).files)
        #expect(graph.groups(.topDown).map(\.isStandalone) == [true])
    }

    @Test func leavesOutDependenciesOnFilesNotChangedAndOnItself() {
        let graph = namedGraph(["a.go", "b.go"], ["a.go": ["a.go", "elsewhere.go"], "gone.go": ["b.go"]])
        #expect(graph.dependencies.isEmpty)
        #expect(graph.groups(.topDown) == [FileGraph.Group(files: ["a.go", "b.go"], isStandalone: true)])
    }

    @Test func placesEachTestStraightAfterTheFileItsNamedForEitherWayUp() {
        let graph = namedGraph(["api/server.go", "store/users.go", "store/users_test.go", "web/Profile.tsx", "web/__tests__/Profile.test.tsx", "Tests/StoreTests/UsersTests.swift", "Sources/Store/Users.swift"], [
            "api/server.go": ["store/users.go"],
            "store/users_test.go": ["store/users.go"],
            "web/__tests__/Profile.test.tsx": ["web/Profile.tsx"],
            "Tests/StoreTests/UsersTests.swift": ["Sources/Store/Users.swift"],
        ])
        #expect(outline(graph, .bottomUp) == [
            "group", "  store/users.go", "  store/users_test.go", "  api/server.go",
            "group", "  Sources/Store/Users.swift", "  Tests/StoreTests/UsersTests.swift",
            "group", "  web/Profile.tsx", "  web/__tests__/Profile.test.tsx",
        ])
        #expect(outline(graph, .topDown) == [
            "group", "  api/server.go", "  store/users.go", "  store/users_test.go",
            "group", "  Sources/Store/Users.swift", "  Tests/StoreTests/UsersTests.swift",
            "group", "  web/Profile.tsx", "  web/__tests__/Profile.test.tsx",
        ])
    }

    @Test func saysWhatUsesAFile() {
        let graph = namedGraph(["core.go", "x.go", "y.go"], ["x.go": ["core.go"], "y.go": ["core.go"]])
        #expect(graph.dependents(of: "core.go") == ["x.go", "y.go"])
        #expect(graph.dependents(of: "x.go").isEmpty)
    }
}

/// Each group as a line saying what kind it is, then its files indented.
private func outline(_ graph: FileGraph, _ order: FileOrder) -> [String] {
    graph.groups(order).flatMap { [$0.isStandalone ? "standalone" : "group"] + $0.files.map { "  \($0)" } }
}

/// The graph of `paths` with `dependencies` as imports, and the links their names make, as tests
/// and READMEs, as the changes would have it.
private func namedGraph(_ paths: [String], _ dependencies: [String: Set<String>]) -> FileGraph {
    let imports = dependencies.flatMap { file, used in used.map { DependencyLink(from: file, to: $0, reason: .imports) } }
    return FileGraph(paths: paths, links: imports + FileDependencies.find(among: paths, contents: [:]))
}
