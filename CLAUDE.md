# Loupe

Native macOS PR-review app. `DESIGN.md` holds the goals and the reasons behind each decision; read it before changing anything structural. `NOTES.md` has the original spike findings and the build/run commands.

## Environment

- No Xcode on this machine, only Command Line Tools: Swift 6.1, SwiftPM, macOS 14 platform. There is no `.xcodeproj`; don't create one.
- `swift build`, `swift test`, `swift run` and `swift package resolve` fail inside the sandbox with an xcrun cache error. Run them with the sandbox off. The same goes for `gh` and anything else needing network.
- The GUI can't be launched or screenshotted from the sandbox. Verify with tests and the build, and tell the user the `swift run Loupe` command to see it themselves.
- To see the UI yourself, run `Scripts/snapshot.sh <dir>` with the sandbox off (it briefly shows windows on the user's screen), then view the PNGs it prints with the Read tool. Set `LOUPE_DATABASE` to a copy of the database to keep the real one untouched; see "Snapshots" in `NOTES.md`.
- Auth is `gh auth token`. Never write the token to disk, logs or fixtures.
- Other checkouts beside this one under `~/Development/` are shared with other sessions: only read-only git there (`fetch`, `diff`, `log`, `remote get-url`). Never checkout, reset, or write.
- Database: `~/Library/Application Support/Loupe/loupe.sqlite`. Tests use temp or in-memory databases.

## Targets

- `LoupeCore`: diff parsing and the `NSTextView`-based diff rendering. No network.
- `LoupeModel`: shared value types.
- `LoupeGitHub`: GraphQL client, hand-written queries and `Codable`, no Apollo.
- `LoupeStore`: SQLite via GRDB, with migrations.
- `LoupeGit`: local checkout discovery and read-only git.
- `LoupeInbox`: the PR list model that wires GitHub, store and UI.
- `Loupe`: the app. `swift run Loupe` opens the PR list; `swift run Loupe <diff>` opens a diff file; `--bench` times the diff view.

## Conventions

- Tests are swift-testing, behaviour-level, driven through the real seams with a fake GitHub transport serving the JSON under `probe/`. Don't unit-test private helpers; don't hit the network.
- Helpers go at the bottom of files. Comments describe behaviour and why, never history.
- Refine types rather than cast with `as`; avoid needless optionals.
- Commit directly to `main` for now; don't push. Headline says what changed, body says why only if not obvious, lines ≤80 chars.
- Markdown files: one line per paragraph and per list item, soft-wrapped, never hard-wrapped to a column.
- Keep `DESIGN.md` current: when a decision is made or reversed, add an entry rather than editing an old one.
