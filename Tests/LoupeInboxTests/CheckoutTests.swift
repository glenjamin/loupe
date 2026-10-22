@testable import LoupeFakeGitHub
import Foundation
import LoupeGit
import LoupeInbox
import LoupeStore
import Testing

@MainActor
struct CheckoutTests {
    @Test func findsACheckoutUnderTheFirstSearchRoot() async throws {
        let disk = try FakeDevelopmentDirectory()
        let atrium = try await disk.checkout("atrium", in: disk.first, origin: "git@github.com:tamarinworks/atrium.git")
        try await disk.checkout("atrium", in: disk.second, origin: "https://github.com/tamarinworks/atrium")
        let model = try disk.listModel()

        await model.refresh()

        #expect(model.checkout(for: "tamarinworks/atrium") == .found(atrium))
        #expect(model.checkout(for: "tamarinworks/marmot") == .notFound)
    }

    @Test func findsACheckoutUnderTheSecondSearchRootWhenTheFirstHasNone() async throws {
        let disk = try FakeDevelopmentDirectory()
        let marmot = try await disk.checkout("marmot", in: disk.second, origin: "https://github.com/tamarinworks/marmot")
        let jest = try await disk.checkout("jest", in: disk.second, origin: "https://github.com/glenjamin/jest.git")
        let model = try disk.listModel()

        await model.refresh()

        #expect(model.checkout(for: "tamarinworks/marmot") == .found(marmot))
        #expect(model.checkout(for: "glenjamin/jest") == .found(jest))
    }

    @Test func rejectsASameNamedDirectoryCheckedOutFromAnotherRepo() async throws {
        let disk = try FakeDevelopmentDirectory()
        let libhoney = try await disk.checkout("libhoney-go", in: disk.first, origin: "git@github.com:honeycombio/libhoney-go.git")
        // A worktree-style copy is never a candidate, even with the right origin.
        try await disk.checkout("lily-bump-atrium", in: disk.first, origin: "https://github.com/tamarinworks/lily")
        let model = try disk.listModel()

        await model.refresh()

        #expect(model.checkout(for: "honeycombio/libhoney-go") == .found(libhoney))
        #expect(model.checkout(for: "tamarinworks/libhoney-go") == .notFound)
        #expect(model.checkout(for: "tamarinworks/lily") == .notFound)
    }

    @Test func findsAForksCheckoutByItsOtherRemotes() async throws {
        let disk = try FakeDevelopmentDirectory()
        let libhoney = try await disk.checkout("libhoney-go", in: disk.first, origin: "https://github.com/tamarinworks/libhoney-go.git", remotes: ["upstream": "https://github.com/honeycombio/libhoney-go.git"])
        let model = try disk.listModel()

        await model.refresh()

        #expect(model.checkout(for: "honeycombio/libhoney-go") == .found(libhoney))
        #expect(model.checkout(for: "tamarinworks/libhoney-go") == .found(libhoney))
    }

    @Test func prefersACheckoutWhoseOriginIsTheRepoOverAForks() async throws {
        let disk = try FakeDevelopmentDirectory()
        try await disk.checkout("libhoney-go", in: disk.first, origin: "https://github.com/tamarinworks/libhoney-go.git", remotes: ["upstream": "https://github.com/honeycombio/libhoney-go.git"])
        let clone = try await disk.checkout("libhoney-go", in: disk.second, origin: "git@github.com:honeycombio/libhoney-go.git")
        let model = try disk.listModel()

        await model.refresh()

        #expect(model.checkout(for: "honeycombio/libhoney-go") == .found(clone))
    }

    @Test func firstLaunchSearchesNowhereUntilFoldersAreChosenThenKeepsThem() async throws {
        let disk = try FakeDevelopmentDirectory()
        let atrium = try await disk.checkout("atrium", in: disk.first, origin: "https://github.com/tamarinworks/atrium")
        let config = ConfigFile(url: disk.root.appending(components: "config", "loupe", "config.json"))
        let model = try disk.listModel(config: config)
        await model.refresh()
        #expect(model.needsCheckoutFolders)
        #expect(model.checkout(for: "tamarinworks/atrium") == .notFound)

        try await model.chooseCheckoutFolders([disk.first, disk.second])

        #expect(!model.needsCheckoutFolders)
        #expect(model.checkout(for: "tamarinworks/atrium") == .found(atrium))
        let nextRun = try disk.listModel(config: config)
        #expect(!nextRun.needsCheckoutFolders)
        #expect(nextRun.checkoutSearchRoots == [disk.first, disk.second])
    }

    @Test func readsHandWrittenCheckoutFoldersUnderTheHomeDirectory() throws {
        let disk = try FakeDevelopmentDirectory()
        let config = ConfigFile(url: disk.root.appending(path: "config.json"))
        try #"{"checkoutFolders": ["~/Development/tamarinworks", "/srv/checkouts"]}"#.write(to: config.url, atomically: true, encoding: .utf8)

        #expect(try config.checkoutFolders() == [
            URL.homeDirectory.appending(path: "Development/tamarinworks", directoryHint: .isDirectory),
            URL(filePath: "/srv/checkouts", directoryHint: .isDirectory),
        ])

        try config.setCheckoutFolders([URL.homeDirectory.appending(path: "src", directoryHint: .isDirectory)])
        #expect(try String(contentsOf: config.url, encoding: .utf8).contains(#""~/src""#), "kept readable for editing by hand")
    }

    @Test func remembersCheckoutsAndLooksAgainForMisses() async throws {
        let disk = try FakeDevelopmentDirectory()
        let store = try PullRequestStore(url: disk.root.appending(path: "loupe.sqlite"))
        let atrium = try await disk.checkout("atrium", in: disk.first, origin: "https://github.com/tamarinworks/atrium")
        try await disk.listModel(store: store).refresh()

        // Next launch searches nowhere, so only what was stored can be found.
        let gazette = try await disk.checkout("gazette", in: disk.first, origin: "https://github.com/tamarinworks/gazette")
        let nextRun = try disk.listModel(store: store, searchRoots: [])
        await nextRun.refresh()
        #expect(nextRun.checkout(for: "tamarinworks/atrium") == .found(atrium))
        #expect(nextRun.checkout(for: "tamarinworks/gazette") == .notFound)

        let searching = try disk.listModel(store: store)
        await searching.refresh()
        #expect(searching.checkout(for: "tamarinworks/gazette") == .found(gazette))
    }

    @Test func aStoredCheckoutThatWasDeletedIsForgottenAndFoundAgain() async throws {
        let disk = try FakeDevelopmentDirectory()
        let store = try PullRequestStore.inMemory()
        let moved = try await disk.checkout("atrium", in: disk.first, origin: "https://github.com/tamarinworks/atrium")
        let model = try disk.listModel(store: store)
        await model.refresh()
        #expect(model.checkout(for: "tamarinworks/atrium") == .found(moved))

        try FileManager.default.removeItem(at: moved)
        let atrium = try await disk.checkout("atrium", in: disk.second, origin: "https://github.com/tamarinworks/atrium")
        await model.refresh()
        #expect(model.checkout(for: "tamarinworks/atrium") == .found(atrium))

        try FileManager.default.removeItem(at: atrium)
        await model.refresh()
        #expect(model.checkout(for: "tamarinworks/atrium") == .notFound)
        #expect(try store.localRepos(for: ["tamarinworks/atrium"]).isEmpty)
    }

    @Test func locatingACheckoutByHandStoresItWhenAnyRemoteMatches() async throws {
        let disk = try FakeDevelopmentDirectory()
        let store = try PullRequestStore.inMemory()
        let elsewhere = disk.root.appending(path: "elsewhere", directoryHint: .isDirectory)
        let bedrock = try await disk.checkout("bedrock-copy", in: elsewhere, origin: "git@github.com:glenjamin/bedrock", remotes: ["upstream": "git@github.com:tamarinworks/bedrock"])
        let model = try disk.listModel(store: store)
        await model.refresh()
        #expect(model.checkout(for: "tamarinworks/bedrock") == .notFound)

        try await model.locateCheckout(for: "tamarinworks/bedrock", at: bedrock)

        #expect(model.checkout(for: "tamarinworks/bedrock") == .found(bedrock))
        let nextRun = try disk.listModel(store: store, searchRoots: [])
        await nextRun.refresh()
        #expect(nextRun.checkout(for: "tamarinworks/bedrock") == .found(bedrock))
    }

    @Test func locatingTheWrongDirectoryByHandIsRejected() async throws {
        let disk = try FakeDevelopmentDirectory()
        let store = try PullRequestStore.inMemory()
        let atrium = try await disk.checkout("atrium", in: disk.second, origin: "https://github.com/tamarinworks/atrium", remotes: ["fork": "https://github.com/glenjamin/atrium"])
        let plain = disk.root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let model = try disk.listModel(store: store, searchRoots: [])
        await model.refresh()

        await #expect(throws: CheckoutError.noMatchingRemote(atrium, expected: "tamarinworks/bedrock", remotes: ["https://github.com/tamarinworks/atrium", "https://github.com/glenjamin/atrium"])) {
            try await model.locateCheckout(for: "tamarinworks/bedrock", at: atrium)
        }
        await #expect(throws: CheckoutError.notAGitRepository(plain)) {
            try await model.locateCheckout(for: "tamarinworks/bedrock", at: plain)
        }

        #expect(model.checkout(for: "tamarinworks/bedrock") == .notFound)
        #expect(try store.localRepos(for: ["tamarinworks/bedrock"]).isEmpty)
    }
}

/// Two search roots in a temp directory, holding real (empty) git repos with an origin remote and
/// any others.
/// Deleted when the test ends.
private final class FakeDevelopmentDirectory: Sendable {
    let root: URL
    let first: URL
    let second: URL

    init() throws {
        // Resolved, so paths compare equal to those git and the resolver report.
        root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory).resolvingSymlinksInPath()
        first = root.appending(path: "tamarinworks", directoryHint: .isDirectory)
        second = root.appending(path: "GitHub", directoryHint: .isDirectory)
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func checkout(_ name: String, in parent: URL, origin: String, remotes: KeyValuePairs<String, String> = [:]) async throws -> URL {
        let directory = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await runGit(["init", "--quiet"], in: directory)
        try await runGit(["remote", "add", "origin", origin], in: directory)
        for (remote, url) in remotes {
            try await runGit(["remote", "add", remote, url], in: directory)
        }
        return directory
    }

    /// A list model over the PR fixture, which includes PRs from all the repos used here.
    @MainActor
    func listModel(store: PullRequestStore? = nil, searchRoots: [URL]? = nil) throws -> PullRequestListModel {
        try PullRequestListModel(
            client: FakeGitHub(fixture: "pr-list.json").client(),
            store: store ?? .inMemory(),
            checkoutSearchRoots: searchRoots ?? [first, second],
            onOpen: { _ in }
        )
    }

    /// A list model over the PR fixture searching the folders `config` has, as the app does.
    @MainActor
    func listModel(config: ConfigFile) throws -> PullRequestListModel {
        try PullRequestListModel(
            client: FakeGitHub(fixture: "pr-list.json").client(),
            store: .inMemory(),
            checkoutSearchRoots: config.checkoutFolders(),
            saveCheckoutFolders: config.setCheckoutFolders,
            onOpen: { _ in }
        )
    }
}
