import Foundation

/// Changed paths arranged as github.com's "Files changed" tree: nested by directory, a run of
/// directories each holding only one directory shown as one node named `a/b/c`, and each
/// directory's subdirectories before its files, each alphabetically.
public struct FileTree: Sendable, Equatable {
    public enum Node: Sendable, Equatable, Identifiable {
        case directory(Directory)
        case file(path: String)

        /// Distinct for a directory and a file at the same path, as when a PR deletes a file
        /// and adds a directory in its place.
        public var id: String {
            switch self {
            case let .directory(directory): directory.path + "/"
            case let .file(path): path
            }
        }

        /// The name shown: a file's last path component, or a directory's, with those of any
        /// single-child directories folded into it.
        public var name: String {
            switch self {
            case let .directory(directory): directory.name
            case let .file(path): path.split(separator: "/").last.map(String.init) ?? path
            }
        }

        /// The directory's contents, nil for a file.
        public var children: [Node]? {
            if case let .directory(directory) = self { directory.children } else { nil }
        }
    }

    public struct Directory: Sendable, Equatable {
        /// The full path of the deepest directory the node stands for.
        public let path: String
        public let name: String
        public let children: [Node]
    }

    public let nodes: [Node]

    public init(paths: some Sequence<String>) {
        var root = Folder()
        for path in paths {
            root.insert(path.split(separator: "/").map(String.init)[...], path: path)
        }
        nodes = root.nodes(under: "")
    }

    /// The files' paths in the order the tree shows them, top to bottom with every directory
    /// expanded.
    public var files: [String] {
        nodes.flatMap(\.files)
    }
}

private extension FileTree.Node {
    var files: [String] {
        switch self {
        case let .directory(directory): directory.children.flatMap(\.files)
        case let .file(path): [path]
        }
    }
}

/// A directory while the tree is being built.
private struct Folder {
    var folders: [String: Folder] = [:]
    var files: [String: String] = [:]

    mutating func insert(_ components: ArraySlice<String>, path: String) {
        guard let first = components.first else { return }
        if components.count == 1 {
            files[first] = path
        } else {
            folders[first, default: Folder()].insert(components.dropFirst(), path: path)
        }
    }

    func nodes(under parent: String) -> [FileTree.Node] {
        let directories = folders.sorted { precedes($0.key, $1.key) }.map { entry -> FileTree.Node in
            var (name, folder) = entry
            var path = parent.isEmpty ? name : "\(parent)/\(name)"
            while folder.files.isEmpty, folder.folders.count == 1, let (child, inner) = folder.folders.first {
                name += "/\(child)"
                path += "/\(child)"
                folder = inner
            }
            return .directory(FileTree.Directory(path: path, name: name, children: folder.nodes(under: path)))
        }
        let leaves = files.sorted { precedes($0.key, $1.key) }.map { FileTree.Node.file(path: $0.value) }
        return directories + leaves
    }
}

/// Alphabetical as a person reads it: case aside, and numbers by value.
private func precedes(_ lhs: String, _ rhs: String) -> Bool {
    let order = lhs.compare(rhs, options: [.caseInsensitive, .numeric])
    return order == .orderedSame ? lhs < rhs : order == .orderedAscending
}
