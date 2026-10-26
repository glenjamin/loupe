# Loupe

Native macOS PR-review app. `DESIGN.md` holds the goals and the reasons behind each decision; read it before changing anything structural. `NOTES.md` has the original spike findings and the build/run commands.

## Environment

- No Xcode on this machine, only Command Line Tools: Swift 6.1, SwiftPM, macOS 14 platform. There is no `.xcodeproj`; don't create one.
- `swift build`, `swift test`, `swift run` and `swift package resolve` fail inside the sandbox with an xcrun cache error. Run them with the sandbox off. The same goes for `gh` and anything else needing network.
- The GUI can't be launched or screenshotted from the sandbox. Verify with tests and the build, and tell the user the `swift run Loupe` command to see it themselves.
- To see the UI yourself, run `Scripts/snapshot.sh <dir>` with the sandbox off, then view the PNGs it prints with the Read tool. Snapshot runs are invisible and off-screen, and never write to GitHub or the checkouts. Set `LOUPE_DATABASE` to a copy of the database to keep the real one untouched; see "Snapshots" in `NOTES.md`.
- To check that clicks, keys and hover do what you built, write a script for `LOUPE_SNAPSHOT_SCRIPT` rather than a new `LOUPE_SNAPSHOT_*` hook: it finds things in the accessibility tree, asserts, writes PNGs and fails the run with a non-zero exit. Add it to the UI suite in `Scripts/ui-tests/`, which runs against the fake GitHub and fixture checkouts, so it stays deterministic. After UI changes run `Scripts/ui-tests.sh` (sandbox off) alongside `swift test`; both must pass. See "Snapshot scripts" in `NOTES.md`.
- Never launch the app any other way (`swift run Loupe`, `open .build/Loupe.app`, the bundle's binary without `LOUPE_SNAPSHOT_DIR`). That opens real, maximised windows on the user's screens and leaves them there. Only `Scripts/snapshot.sh`, `Scripts/ui-tests.sh` and `--bench` are allowed.
- Auth is `gh auth token`. Never write the token to disk, logs or fixtures.
- Other git checkouts on this machine are in use by other sessions. While testing, only read from them (`fetch`, `diff`, `log`, `remote get-url`); never checkout, reset, commit or otherwise write.
- Database: `~/Library/Application Support/Loupe/loupe.sqlite`. Tests use temp or in-memory databases.

## Targets

- `LoupeCore`: diff parsing and the `NSTextView`-based diff rendering. No network.
- `TreeSitterProto`: the vendored Protocol Buffers grammar (C) and its highlights query; refreshed by `Scripts/update-tree-sitter-proto.sh`, never edited by hand.
- `LoupeModel`: shared value types.
- `LoupeGitHub`: GraphQL client, hand-written queries and `Codable`, no Apollo.
- `LoupeStore`: SQLite via GRDB, with migrations.
- `LoupeGit`: local checkout discovery and read-only git.
- `LoupeInbox`: the PR list model that wires GitHub, store and UI.
- `Loupe`: the app. `swift run Loupe` opens its one window, the PR lists with a tab strip of open PRs under the title bar; `swift run Loupe <diff>` opens a diff file; `--bench` times the diff view.

## Conventions

- Tests are swift-testing, behaviour-level, driven through the real seams with a fake GitHub transport serving the JSON under `probe/`. Don't unit-test private helpers; don't hit the network.
- Helpers go at the bottom of files. Comments describe behaviour and why, never history.
- Refine types rather than cast with `as`; avoid needless optionals.
- Warnings are errors in every Swift target of ours (`strictSwift()` in `Package.swift`; give new targets it too). Fix them; don't suppress or disable them.
- Commit directly to `main` and push to `origin` (github.com/glenjamin/loupe, private); no branches or PRs. Headline says what changed, body says why only if not obvious, lines ≤80 chars.
- The repo is public and meant to be general. Saying in passing that something is used at Geckoboard, and roughly how, is fine; keep the internals of private repos and tools (their names, code, hosts, data) out of code, docs, fixtures and commits, and build features against generic contracts.
- Markdown files: one line per paragraph and per list item, soft-wrapped, never hard-wrapped to a column.
- Keep `DESIGN.md` current: when a decision is made or reversed, add an entry rather than editing an old one.
