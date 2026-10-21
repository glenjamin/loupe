@testable import LoupeFakeGitHub
import CoreGraphics
import Foundation
import ImageIO
import LoupeCore
import LoupeGit
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ImageTests {
    @Test func anAddedImageShowsOnlyItsNewVersion() async throws {
        let app = try await ImageApp()
        let repo = try await FakeRepository()
        let logo = try png(width: 4, height: 3)
        let pullRequest = try await app.pushPullRequest(in: repo, commits: [["assets/logo.png": logo]])
        let tab = try await app.open(pullRequest)
        let file = try #require(tab.file("assets/logo.png"))
        #expect(file.isBinary)

        let change = try #require(tab.imageChange(of: file))
        #expect(change.kind == .raster)
        #expect(change.old == nil)
        let new = try #require(change.new)
        #expect(tab.images.image(new) == nil, "read only once shown")

        await tab.loadImages(change)

        #expect(tab.images.image(new) == .ready(logo))
    }

    @Test func aDeletedImageShowsItsOldVersion() async throws {
        let app = try await ImageApp()
        let repo = try await FakeRepository()
        let logo = try png(width: 4, height: 3)
        let pullRequest = try await app.pushPullRequest(in: repo, startingWith: ["logo.png": logo], commits: [["logo.png": nil]])
        let tab = try await app.open(pullRequest)
        let change = try #require(tab.file("logo.png").flatMap(tab.imageChange(of:)))
        #expect(change.new == nil)

        await tab.loadImages(change)

        #expect(tab.images.image(try #require(change.old)) == .ready(logo), "a deleted file is still there at the base")
    }

    @Test func aChangedImageReadsBothVersionsLeavingTheCheckoutAlone() async throws {
        let app = try await ImageApp()
        let repo = try await FakeRepository()
        let before = try png(width: 4, height: 3)
        let after = try png(width: 6, height: 3)
        let pullRequest = try await app.pushPullRequest(in: repo, startingWith: ["logo.png": before], commits: [["logo.png": after]])
        let checkout = try await repo.checkoutState()
        let tab = try await app.open(pullRequest)
        let change = try #require(tab.file("logo.png").flatMap(tab.imageChange(of:)))

        await tab.loadImages(change)

        #expect(tab.images.image(try #require(change.old)) == .ready(before))
        #expect(tab.images.image(try #require(change.new)) == .ready(after))
        #expect(try await repo.checkoutState() == checkout)
        #expect(tab.images.mode(of: "logo.png") == .twoUp, "2-up until another way is picked")
        tab.images.setMode(.onionSkin, path: "logo.png")
        #expect(tab.images.mode(of: "logo.png") == .onionSkin)
    }

    @Test func aRenamedImageComparesWithItsOldName() async throws {
        let app = try await ImageApp()
        let repo = try await FakeRepository()
        let logo = try png(width: 4, height: 3)
        let pullRequest = try await app.pushPullRequest(in: repo, startingWith: ["old/logo.png": logo], commits: [["old/logo.png": nil, "new/logo.png": logo]])
        let tab = try await app.open(pullRequest)
        let change = try #require(tab.file("new/logo.png").flatMap(tab.imageChange(of:)))
        #expect(change.old?.path == "old/logo.png")

        await tab.loadImages(change)

        #expect(tab.images.image(try #require(change.old)) == .ready(logo))
        #expect(tab.images.image(try #require(change.new)) == .ready(logo))
    }

    @Test func aPickedCommitComparesItsOwnVersions() async throws {
        let app = try await ImageApp()
        let repo = try await FakeRepository()
        let first = try png(width: 2, height: 2)
        let second = try png(width: 3, height: 2)
        let pullRequest = try await app.pushPullRequest(in: repo, commits: [["logo.png": first], ["logo.png": second]])
        let tab = try await app.open(pullRequest)
        #expect(tab.file("logo.png").flatMap(tab.imageChange(of:))?.old == nil, "all the PR's changes add it")
        let review = try #require(tab.ready)

        await tab.show(.commit(review.commits[1].oid))
        let change = try #require(tab.file("logo.png").flatMap(tab.imageChange(of:)))
        await tab.loadImages(change)

        #expect(tab.images.image(try #require(change.old)) == .ready(first))
        #expect(tab.images.image(try #require(change.new)) == .ready(second))
    }

    @Test func anSVGShowsItsDiffUntilAskedToRender() async throws {
        let app = try await ImageApp()
        let repo = try await FakeRepository()
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#.utf8)
        let pullRequest = try await app.pushPullRequest(in: repo, commits: [["icon.svg": svg, "notes.bin": Data([0, 1, 2])]])
        let tab = try await app.open(pullRequest)
        let icon = try #require(tab.file("icon.svg"))
        #expect(!icon.hunks.isEmpty, "an SVG is text, with a diff of its own")
        #expect(tab.imageChange(of: icon)?.kind == .svg)
        #expect(tab.imageChange(of: try #require(tab.file("notes.bin"))) == nil, "only images are shown as images")
        #expect(!tab.images.isRendered("icon.svg"))

        tab.images.setRendered(true, path: "icon.svg")
        await tab.loadImages(try #require(tab.imageChange(of: icon)))

        #expect(tab.images.isRendered("icon.svg"))
        #expect(tab.images.image(try #require(tab.imageChange(of: icon)?.new)) == .ready(svg))
    }

    @Test func anImageOverTheLimitIsOnlyMeasured() async throws {
        let repo = try await FakeRepository()
        let image = try png(width: 64, height: 64)
        let head = try await repo.commit(binary: ["big.png": image])
        try await repo.push()
        let differ = PullRequestDiffer()

        #expect(try await differ.blob(of: "big.png", at: head, in: repo.contributorDirectory, limit: image.count - 1) == .tooLarge(bytes: image.count))
        #expect(try await differ.blob(of: "big.png", at: head, in: repo.contributorDirectory, limit: image.count) == .contents(image))
    }
}

@MainActor
private struct ImageApp {
    let github: FakeGitHub
    let details = FakePullRequestDetails()
    let store: PullRequestStore
    let tabs: TabsModel

    init() async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        store = try PullRequestStore.inMemory()
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        tabs = TabsModel.manuallyTimed(lists: lists, store: store, client: details.client(), notifications: github.notifications())
        await tabs.lists.refresh()
    }

    /// Makes the first to-review PR a commit for each of `commits`, writing its files (nil
    /// deletes one) in `repo`, branched from a commit on main writing `base`, and returns it as
    /// the lists now have it.
    func pushPullRequest(in repo: FakeRepository, startingWith base: [String: Data?] = [:], commits: [[String: Data?]]) async throws -> PullRequestSummary {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = base.isEmpty ? try await repo.git(["rev-parse", "HEAD"], in: repo.checkout) : try await repo.commit(binary: base)
        try await repo.push()
        try await repo.switchTo("feature", creatingFrom: "main")
        var last = branchPoint
        for files in commits { last = try await repo.commit(binary: files) }
        let head = last
        try await repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = head; $0.baseRefOid = branchPoint }
        await tabs.lists.refresh()
        return try #require(tabs.lists.pullRequest(id: listed.id))
    }

    func open(_ pullRequest: PullRequestSummary) async throws -> PullRequestTab {
        tabs.open(pullRequest)
        let tab = try #require(tabs.tab(id: pullRequest.id))
        await tab.load()
        return tab
    }
}

private extension FakeRepository {
    /// Commits the files' bytes to the contributor's current branch (nil deletes one), and
    /// returns the commit's oid.
    func commit(binary files: [String: Data?]) async throws -> String {
        for (path, contents) in files {
            let url = contributorDirectory.appending(path: path)
            if let contents {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
        try await git(["add", "--all"], in: contributorDirectory)
        try await git(["commit", "--quiet", "-m", "Change images"], in: contributorDirectory)
        return try await git(["rev-parse", "HEAD"], in: contributorDirectory)
    }
}

/// A PNG of a flat colour, its size telling one version from another.
private func png(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
