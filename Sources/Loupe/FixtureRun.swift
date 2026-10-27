import Foundation
import LoupeFakeGitHub
import LoupeGit
import LoupeGitHub
import WebKit

/// `LOUPE_FIXTURES=<dir>` makes a snapshot run hermetic, for the UI suite (`Scripts/ui-tests.sh`):
/// GitHub is `FixtureGitHub`, in-process, serving the anonymised captures under `probe/`, with no
/// network and no `gh` token; the database starts empty at `<dir>/loupe.sqlite` unless
/// `LOUPE_DATABASE` says otherwise; checkouts are looked for only in `<dir>/checkouts`, where
/// `Loupe --fixture-checkouts <dir>/checkouts` builds them, unless `<dir>/config.json` says otherwise; the lists judge age by a fixed time
/// near the captures; the real app's settings aren't read; web pages load nothing from the
/// network; and CircleCI is `FakeCircleCI`, or for an artifact a CLI that doesn't exist. Snapshot
/// runs' write guards stay on.
@MainActor
enum FixtureRun {
    static let directory = SnapshotRun.directory == nil ? nil : ProcessInfo.processInfo.environment["LOUPE_FIXTURES"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
    }
    static let checkouts = directory?.appending(path: "checkouts", directoryHint: .isDirectory)
    /// The run's own config file, which a script's `<name>.config.json` becomes in the UI suite.
    static let config = directory.map { ConfigFile(url: $0.appending(path: "config.json")) }
    /// The checkouts as the folder to search, unless the run has a config file to say otherwise.
    static var checkoutsWithoutConfig: URL? {
        guard let config, !FileManager.default.fileExists(atPath: config.url.path(percentEncoded: false)) else { return nil }
        return checkouts
    }
    static let gitHub = checkouts.map(FixtureGitHub.init(checkouts:))
    /// CircleCI's jobs for the fixtures' failed checks, in-process.
    static let circleCI = directory == nil ? nil : FakeCircleCI.fixture()
    /// Where the run's PRs are kept unless `LOUPE_DATABASE` says otherwise.
    static let database = directory.map { directory in
        ProcessInfo.processInfo.environment["LOUPE_DATABASE"].map { URL(filePath: $0) } ?? directory.appending(path: "loupe.sqlite")
    }
    /// Noon on the day `pr-list.json` was captured, so which PRs count as quiet or stale stays put.
    static let now = Date(timeIntervalSince1970: 1_791_979_200)
    /// Keeps web pages from loading anything over the network, such as avatars; set by `prepare()`.
    private(set) static var offline: WKContentRuleList?

    /// Gets what the run needs before any page is made.
    static func prepare() async {
        guard let directory else { return }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        let store = WKContentRuleListStore(url: directory.appending(path: "content-rules", directoryHint: .isDirectory))
        offline = try? await store?.compileContentRuleList(forIdentifier: "offline", encodedContentRuleList: rules)
    }

    /// The environment CircleCI's CLI and token command run in: in a fixture run, CLIs that don't
    /// exist, so a report says CircleCI can't be reached rather than asking it.
    static var circleCIEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard let directory else { return environment }
        environment["LOUPE_CIRCLECI"] = directory.appending(path: "no-circleci").path(percentEncoded: false)
        environment["LOUPE_CIRCLECI_TOKEN_COMMAND"] = directory.appending(path: "no-circleci-token").path(percentEncoded: false)
        environment["LOUPE_ARTIFACT_CACHE"] = directory.appending(path: "artifacts").path(percentEncoded: false)
        return environment
    }

    /// Builds the fixture checkouts in `directory`, for `Loupe --fixture-checkouts <dir>`.
    nonisolated static func buildCheckouts(in directory: URL) async -> Int32 {
        do {
            try await FixtureCheckouts.build(in: directory)
            return 0
        } catch {
            FileHandle.standardError.write(Data("Couldn't build the fixture checkouts in \(directory.path(percentEncoded: false)): \(error)\n".utf8))
            return 1
        }
    }
}
