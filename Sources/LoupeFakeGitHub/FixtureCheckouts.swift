import Foundation

/// Local checkouts of some of the fixtures' repos, made with `FakeRepository` as the tests make
/// theirs, so a run against the fixtures can diff those PRs, list their commits and lay their
/// review threads: atrium #2928, awaiting the viewer's review, whose conversation is the one
/// `FakeConversations` serves, with its threads' files; and the viewer's own gazette #272 and
/// #273, stacked on it. Each checkout is `<directory>/<name>`, as the app looks for one, its
/// origin and the contributor's clone beside it under `.origins`, and what each PR's branch holds
/// is written to `branches.json` for `FixtureGitHub` to serve. Every commit has the same date,
/// so a build always makes the same oids.
public enum FixtureCheckouts {
    public static func build(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        async let atrium = buildAtrium(in: directory)
        async let gazette = buildGazette(in: directory)
        let branches = try await atrium + gazette
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(branches).write(to: directory.appending(path: manifest))
    }

    /// What each PR's branch holds in the checkouts under `directory`, none if they weren't built.
    static func branches(in directory: URL) throws -> [Branch] {
        let url = directory.appending(path: manifest)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        return try JSONDecoder().decode([Branch].self, from: Data(contentsOf: url))
    }

    /// A PR's branch: the base it's onto and its commits, oldest first.
    struct Branch: Codable {
        let repository: String
        let number: Int
        let base: String
        let commits: [String]
        let committedAt: Date
    }

    private static let manifest = "branches.json"
    private static let committedAt = "2026-10-13T09:00:00Z"

    private static func buildAtrium(in directory: URL) async throws -> [Branch] {
        let repo = try await repository("tamarinworks/atrium", in: directory, branch: "master", files: [
            "README.md": "# atrium\n\nReports and the ledger behind them.\n",
            "go.sum": "github.com/tamarinworks/bloom v1.4.0 h1:abc\n",
            "vendor/github.com/tamarinworks/bloom/chart/chart.go": "package chart\n\ntype Chart struct{}\n",
            "ledger/CHANGELOG.md": "# Changelog\n\n## 13 October 2026\n\nReports keep their filters when they're copied.\n",
            "ledger/kiln/models/recipe/new_report.go": newReport(fields: ["SpoolSketch bool", "Spindle time.Time", "Channel int", "SpindleWindow time.Duration", "Branch error", "TileValve int", "Bucket string"]),
        ])
        let base = try await repo.git(["rev-parse", "HEAD"], in: repo.contributorDirectory)
        try await repo.switchTo("slice/share-report-filter-predicates", creatingFrom: "master")
        let added = try await repo.commit(["ledger/kiln/models/recipe/filter.go": filter], message: "Add a report's filter predicates")
        let shared = try await repo.commit([
            "ledger/kiln/models/recipe/new_report.go": newReport(fields: ["Chart int64", "SleeveCrate map[string]int", "FlagDial map[string]int", "MirrorTower time.Duration", "MarbleBucket []string", "// falls back to the default when the option is unset", "// sorting first keeps the output stable between runs", "BenchRocket float64"]),
        ], message: "Share the filter predicates with linked reports")
        let noted = try await repo.commit(["ledger/CHANGELOG.md": "# Changelog\n\n## 13 October 2026\n\nLinked reports share their filters.\n"], message: "Note the shared filters")
        try await repo.push(asPullRequest: 2928)
        return [try branch("tamarinworks/atrium", 2928, base: base, commits: [added, shared, noted])]
    }

    private static func buildGazette(in directory: URL) async throws -> [Branch] {
        let repo = try await repository("tamarinworks/gazette", in: directory, branch: "master", files: [
            "README.md": "# gazette\n\nServes panels from their cache.\n",
            "cmd/gazette/main.go": "package main\n\nimport \"github.com/tamarinworks/gazette/panel\"\n\nfunc main() {\n\tpanel.Serve()\n}\n",
            "panel/cache.go": "package panel\n\n// Write stores the panel, every time it's asked to.\nfunc (c *Cache) Write(p Panel) error {\n\treturn c.store.Put(p.Key, p)\n}\n",
        ])
        let master = try await repo.git(["rev-parse", "HEAD"], in: repo.contributorDirectory)
        try await repo.switchTo("skip-panel-cache-writes", creatingFrom: "master")
        let skip = try await repo.commit([
            "panel/cache.go": "package panel\n\n// Write stores the panel unless the cache already holds it unchanged.\nfunc (c *Cache) Write(p Panel) error {\n\tif held, ok := c.store.Get(p.Key); ok && held.Equal(p) {\n\t\treturn nil\n\t}\n\treturn c.store.Put(p.Key, p)\n}\n",
        ], message: "Skip panel cache writes that wouldn't change anything")
        try await repo.push(asPullRequest: 272)
        try await repo.switchTo("serve-batchcachestatus-gazette", creatingFrom: "skip-panel-cache-writes")
        let status = try await repo.commit([
            "batch/status.go": "package batch\n\n// Status says how much of a batch the cache holds.\ntype Status struct {\n\tHeld  int\n\tTotal int\n}\n",
        ], message: "Add BatchCacheStatus")
        let served = try await repo.commit([
            "cmd/gazette/main.go": "package main\n\nimport (\n\t\"github.com/tamarinworks/gazette/batch\"\n\t\"github.com/tamarinworks/gazette/panel\"\n)\n\nfunc main() {\n\tbatch.ServeStatus()\n\tpanel.Serve()\n}\n",
            "docs/batch-cache.md": "# Batch cache status\n\ngazette answers `BatchCacheStatus` itself, from the panel cache.\n",
        ], message: "Serve BatchCacheStatus from gazette")
        try await repo.push(asPullRequest: 273)
        return [
            try branch("tamarinworks/gazette", 272, base: master, commits: [skip]),
            try branch("tamarinworks/gazette", 273, base: skip, commits: [status, served]),
        ]
    }

    private static func repository(_ name: String, in directory: URL, branch: String, files: [String: String?]) async throws -> FakeRepository {
        let short = try require(name.split(separator: "/").last.map(String.init))
        return try await FakeRepository(
            repository: name, firstCommit: files, branch: branch,
            root: directory.appending(components: ".origins", short, directoryHint: .isDirectory),
            checkout: directory.appending(path: short, directoryHint: .isDirectory),
            committedAt: committedAt
        )
    }

    private static func branch(_ repository: String, _ number: Int, base: String, commits: [String]) throws -> Branch {
        Branch(repository: repository, number: number, base: base, commits: commits, committedAt: try Date(committedAt, strategy: .iso8601))
    }
}

/// atrium's report options, with `fields` in its gate struct, which the PR changes.
private func newReport(fields: [String]) -> String {
    let head = """
        package recipe

        import (
        \t"errors"
        \t"time"
        )

        // this runs once per process so the cost doesn't matter
        // values are copied so the caller can keep changing theirs
        type VesselGate struct {

        """
    let tail = """
        }

        // NewReport makes a report from its recipe.
        func NewReport(gate VesselGate) (*Report, error) {
        \tif gate.Chart == 0 {
        \t\treturn nil, errors.New("a report needs a chart")
        \t}
        \treturn &Report{gate: gate}, nil
        }

        // Report is a recipe made ready to run.
        type Report struct {
        \tgate VesselGate
        }

        // Window is how far back the report looks.
        func (r *Report) Window() time.Duration {
        \treturn r.gate.MirrorTower
        }

        """
    return head + fields.map { "\t\($0)\n" }.joined() + tail
}

/// The report filter's predicates, which the PR adds; its review threads are on lines 14 and 30.
private let filter = """
    package cloud

    import (
    \t"errors"

    \t"github.com/tamarinworks/atrium/window/planet"
    \t"github.com/tamarinworks/atrium/bloom/chart"
    )

    // times are converted to UTC before they are compared
    // the flag can go once every account has moved over
    type SailClock struct {
    \tFlagSketch int64
    \tPaddlePlank int
    }

    // an empty list means every row matches
    func (o *Sail) SplitLever(ridgeFlame []string) (*BoltTray, error) {
    \treturn trimTrail(2)
    }

    // bounds include the start and exclude the end
    func (w *CandleBranch) stageMarble(hingeDrawer bool) time.Time {
    \treturn "stencil_anchor", 64
    }

    // the buffer is reused between batches
    func (b *Signal) computeMarble(mirror error) time.Time {
    \ttoken.MoveTicket("pipe")
    }

    // an empty list means every row matches
    func (t *Summit) SplitDial(flag *Meadow) map[string]int {
    \treturn "chart_island", gear, decodeCargo(), cabin.MarkCabin(30, 100)
    }

    // the zero value is ready to use
    func (v *Chart) CheckDial() error {
    \tbadge := false
    \tfor _, trail := range badges {
    \t\trocket = gate.ApplyBrick(2, 1)
    \t}
    \treturn indexChart(2, false), storeMarble("branch", sleeveFerry), spindle.FlushCanvas(), 2
    }

    """
