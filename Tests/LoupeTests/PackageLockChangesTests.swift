import LoupeCore
import Testing

struct PackageLockChangesTests {
    @Test func aV3LockfileListsPackagesAddedRemovedUpdatedAndMovedInKeyOrder() throws {
        let base = """
        {
          "name": "demo-app",
          "lockfileVersion": 3,
          "packages": {
            "": { "name": "demo-app", "version": "1.0.0", "dependencies": { "fizzle": "^2.0.0" } },
            "node_modules/fizzle": { "version": "2.0.0", "resolved": "https://registry.example/fizzle-2.0.0.tgz" },
            "node_modules/old-widget": { "version": "0.3.1" },
            "node_modules/fizzle/node_modules/sprocket": { "version": "1.4.0" },
            "node_modules/@acme/gears": { "version": "5.0.0" }
          }
        }
        """
        let head = """
        {
          "name": "demo-app",
          "lockfileVersion": 3,
          "packages": {
            "": { "name": "demo-app", "version": "1.1.0", "dependencies": { "fizzle": "^2.1.0" } },
            "node_modules/fizzle": { "version": "2.1.0", "resolved": "https://registry.example/fizzle-2.1.0.tgz" },
            "node_modules/sprocket": { "version": "1.4.0" },
            "node_modules/@acme/gears": { "version": "5.0.0", "integrity": "sha512-changed" },
            "node_modules/@acme/bolts": { "version": "0.0.9" }
          }
        }
        """

        let changes = try PackageLockChanges.compare(base: base, head: head)

        #expect(changes.changes == [
            .added(key: "node_modules/@acme/bolts", version: "0.0.9"),
            .updated(key: "node_modules/fizzle", from: "2.0.0", to: "2.1.0"),
            .moved(from: "node_modules/fizzle/node_modules/sprocket", to: "node_modules/sprocket", version: "1.4.0"),
            .removed(key: "node_modules/old-widget", version: "0.3.1"),
        ], "the root's own version isn't a package change, nor is integrity alone")
        #expect(changes.summary == "4 packages changed: 1 added, 1 removed, 1 updated, 1 moved")
    }

    @Test func aV1LockfileComparesItsNestedDependenciesByWhereTheyInstall() throws {
        let base = """
        {
          "name": "demo-app",
          "lockfileVersion": 1,
          "dependencies": {
            "fizzle": { "version": "2.0.0", "dependencies": { "sprocket": { "version": "1.0.0" } } },
            "sprocket": { "version": "2.0.0" }
          }
        }
        """
        let head = """
        {
          "name": "demo-app",
          "lockfileVersion": 1,
          "dependencies": {
            "fizzle": { "version": "2.0.0", "dependencies": { "sprocket": { "version": "1.0.1" } } },
            "sprocket": { "version": "2.0.0" },
            "wobble": { "version": "0.1.0" }
          }
        }
        """

        let changes = try PackageLockChanges.compare(base: base, head: head)

        #expect(changes.changes == [
            .updated(key: "node_modules/fizzle/node_modules/sprocket", from: "1.0.0", to: "1.0.1"),
            .added(key: "node_modules/wobble", version: "0.1.0"),
        ])
        #expect(changes.summary == "2 packages changed: 1 added, 1 updated")
    }

    @Test func aMoveFromV1ToV3KeepsUnchangedPackagesOutOfTheList() throws {
        let base = #"{ "lockfileVersion": 1, "dependencies": { "fizzle": { "version": "2.0.0" } } }"#
        let head = #"{ "lockfileVersion": 3, "packages": { "": { "name": "demo-app" }, "node_modules/fizzle": { "version": "2.0.0" } } }"#

        let changes = try PackageLockChanges.compare(base: base, head: head)

        #expect(changes.changes.isEmpty)
        #expect(changes.summary == "No package changes")
    }

    @Test func linkedWorkspacesShowWhereTheyLinkAndTheRootIsSkipped() throws {
        let base = """
        {
          "lockfileVersion": 3,
          "packages": {
            "": { "name": "demo-monorepo", "workspaces": ["packages/*"] },
            "packages/tools": { "name": "@demo/tools", "version": "1.0.0" },
            "node_modules/@demo/tools": { "resolved": "packages/tools", "link": true }
          }
        }
        """
        let head = """
        {
          "lockfileVersion": 3,
          "packages": {
            "": { "name": "demo-monorepo-renamed", "workspaces": ["libs/*"] },
            "libs/tools": { "name": "@demo/tools", "version": "1.0.0" },
            "node_modules/@demo/tools": { "resolved": "libs/tools", "link": true },
            "libs/untitled": { "version": "0.0.1" }
          }
        }
        """

        let changes = try PackageLockChanges.compare(base: base, head: head)

        #expect(changes.changes == [
            .updated(key: "node_modules/@demo/tools", from: "link:packages/tools", to: "link:libs/tools"),
            .moved(from: "packages/tools", to: "libs/tools", version: "1.0.0"),
        ], "a path outside node_modules with no name isn't a package")
    }

    @Test func anAddedLockfileIsAllAdditionsAndADeletedOneAllRemovals() throws {
        let lockfile = #"{ "lockfileVersion": 3, "packages": { "node_modules/fizzle": { "version": "2.0.0" }, "node_modules/wobble": {} } }"#

        #expect(try PackageLockChanges.compare(base: nil, head: lockfile).changes == [
            .added(key: "node_modules/fizzle", version: "2.0.0"),
            .added(key: "node_modules/wobble", version: "(unknown version)"),
        ])
        #expect(try PackageLockChanges.compare(base: lockfile, head: nil).summary == "2 packages changed: 2 removed")
    }

    @Test func aLockfileThatIsntJSONOrListsNoPackagesFailsToCompare() {
        let lockfile = #"{ "lockfileVersion": 3, "packages": {} }"#

        #expect(throws: PackageLockError.notJSON) { try PackageLockChanges.compare(base: "<<<<<<< HEAD", head: lockfile) }
        #expect(throws: PackageLockError.noPackages) { try PackageLockChanges.compare(base: lockfile, head: #"{ "name": "demo-app" }"#) }
    }

    @Test func onlyNpmLockfilesAreCompared() {
        #expect(PackageLockChanges.isPackageLock("package-lock.json"))
        #expect(PackageLockChanges.isPackageLock("web/npm-shrinkwrap.json"))
        #expect(!PackageLockChanges.isPackageLock("yarn.lock"))
        #expect(!PackageLockChanges.isPackageLock("package.json"))
    }
}
