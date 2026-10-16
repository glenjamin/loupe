import Foundation

/// The dependency changes between two versions of an npm lockfile (`package-lock.json` or
/// `npm-shrinkwrap.json`), as the `diff-package-lock` tool reports them: packages added,
/// removed, at a new version, or moved to another place in `node_modules` at the same version.
/// Fields other than the version, such as `resolved` and `integrity`, aren't compared.
public struct PackageLockChanges: Sendable, Equatable {
    /// Sorted by key.
    public let changes: [PackageLockChange]

    /// The files whose dependency changes this shows.
    public static func isPackageLock(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "package-lock.json" || name == "npm-shrinkwrap.json"
    }

    /// Compares two lockfiles' text; nil for a side the file doesn't exist on, which has no
    /// packages. Throws if either isn't a lockfile.
    public static func compare(base: String?, head: String?) throws -> PackageLockChanges {
        let before = try base.map(packages) ?? [:]
        let after = try head.map(packages) ?? [:]

        var changes: [PackageLockChange] = []
        var removed: [Package] = []
        var added: [Package] = []
        for (key, old) in before {
            if let new = after[key] {
                if new.version != old.version { changes.append(.updated(key: key, from: old.version, to: new.version)) }
            } else {
                removed.append(old)
            }
        }
        for (key, new) in after where before[key] == nil {
            added.append(new)
        }

        // A package gone from one place and come to another at the same version has moved,
        // as when npm hoists or nests it.
        var arrivals = Dictionary(grouping: added.sorted { $0.key < $1.key }, by: \.identity)
        for old in removed.sorted(by: { $0.key < $1.key }) {
            if let new = arrivals[old.identity]?.first {
                arrivals[old.identity]?.removeFirst()
                changes.append(.moved(from: old.key, to: new.key, version: old.version))
            } else {
                changes.append(.removed(key: old.key, version: old.version))
            }
        }
        for new in arrivals.values.joined() {
            changes.append(.added(key: new.key, version: new.version))
        }
        return PackageLockChanges(changes: changes.sorted { $0.key < $1.key })
    }

    public var added: Int { changes.count(where: { if case .added = $0 { true } else { false } }) }
    public var removed: Int { changes.count(where: { if case .removed = $0 { true } else { false } }) }
    public var updated: Int { changes.count(where: { if case .updated = $0 { true } else { false } }) }
    public var moved: Int { changes.count(where: { if case .moved = $0 { true } else { false } }) }

    /// "12 packages changed: 3 added, 2 removed, 7 updated", leaving out kinds with none, or
    /// "No package changes".
    public var summary: String {
        guard !changes.isEmpty else { return "No package changes" }
        let kinds = [(added, "added"), (removed, "removed"), (updated, "updated"), (moved, "moved")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
        return "\(changes.count) \(changes.count == 1 ? "package" : "packages") changed: \(kinds.joined(separator: ", "))"
    }
}

/// One package's change. A key is the package's place in the lockfile: its path in
/// `node_modules`, such as `node_modules/a/node_modules/b`, or a workspace's directory.
public enum PackageLockChange: Sendable, Equatable {
    case added(key: String, version: String)
    case removed(key: String, version: String)
    case updated(key: String, from: String, to: String)
    /// The same name and version, in another place.
    case moved(from: String, to: String, version: String)

    /// Where it is, or for a move where it was.
    public var key: String {
        switch self {
        case .added(let key, _), .removed(let key, _), .updated(let key, _, _): key
        case .moved(let from, _, _): from
        }
    }
}

public enum PackageLockError: Error, LocalizedError, Equatable {
    /// The text isn't JSON, or not an object.
    case notJSON
    /// Neither `packages` nor `dependencies` is an object of packages.
    case noPackages

    public var errorDescription: String? {
        switch self {
        case .notJSON: "The lockfile isn't a JSON object."
        case .noPackages: "The lockfile lists no packages or dependencies."
        }
    }
}

/// A package in one place in the tree.
private struct Package {
    let key: String
    let name: String
    let version: String

    /// What a move keeps: the same name at the same version.
    var identity: String { "\(name)@\(version)" }
}

/// The lockfile's packages by key. Lockfile v2 and v3 list `packages` by path; v1 lists
/// `dependencies` by name, nested under the packages that need their own copy, which are keyed
/// by the path they'd be installed at so a v1 file compares with a v2 one.
private func packages(in text: String) throws -> [String: Package] {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let lockfile = object as? [String: Any] else {
        throw PackageLockError.notJSON
    }
    if let tree = lockfile["packages"] as? [String: Any] {
        var packages: [String: Package] = [:]
        for (key, value) in tree {
            // The root is the project itself, not a dependency.
            guard !key.isEmpty, let spec = value as? [String: Any], let name = spec["name"] as? String ?? nameAfterNodeModules(key) else { continue }
            let version = if spec["link"] as? Bool == true, let resolved = spec["resolved"] as? String {
                "link:\(resolved)"
            } else {
                spec["version"] as? String ?? "(unknown version)"
            }
            packages[key] = Package(key: key, name: name, version: version)
        }
        return packages
    }
    if let dependencies = lockfile["dependencies"] as? [String: Any] {
        var packages: [String: Package] = [:]
        addDependencies(dependencies, under: "", to: &packages)
        return packages
    }
    throw PackageLockError.noPackages
}

/// Adds lockfile v1's `dependencies`, and theirs, as installed under `prefix`.
private func addDependencies(_ dependencies: [String: Any], under prefix: String, to packages: inout [String: Package]) {
    for (name, value) in dependencies {
        guard let spec = value as? [String: Any] else { continue }
        let key = "\(prefix)node_modules/\(name)"
        packages[key] = Package(key: key, name: name, version: spec["version"] as? String ?? "(unknown version)")
        if let nested = spec["dependencies"] as? [String: Any] {
            addDependencies(nested, under: key + "/", to: &packages)
        }
    }
}

/// The package name a path installs, after its last `node_modules/`; nil for a path outside
/// `node_modules`.
private func nameAfterNodeModules(_ key: String) -> String? {
    guard let range = key.range(of: "node_modules/", options: .backwards) else { return nil }
    let name = key[range.upperBound...]
    return name.isEmpty ? nil : String(name)
}
