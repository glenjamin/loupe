# Loupe spike: findings

A spike for a native macOS PR-review app. It checks the GitHub GraphQL data shapes we'd need (`probe/`) and prototypes the diff view, the riskiest part (`Sources/`).

## Build and run

Needs Swift 6 (Command Line Tools are enough; no Xcode). All commands run from the project root.

```sh
swift build                 # debug build
swift test                  # diff tests, plus PR list tests against a fake GitHub and SQLite (swift-testing)
swift build -c release      # for meaningful bench numbers
```

Open the start screen: your open PRs (drafts included) beside the open PRs awaiting your review, newest first. It authenticates with `gh auth token`, so `gh` must be signed in. Clicking a PR (or selecting it with the arrow keys and pressing Return) opens it in a window tab:

```sh
swift run Loupe
```

The PRs are kept in SQLite at `~/Library/Application Support/Loupe/loupe.sqlite`, so launch shows the last-known lists straight away, then refreshes in the background: on launch, every few minutes, on ⌘R, and when the app comes to the front with lists more than a few minutes old. A list's first load pages through its search for open PRs in full and makes the stored list match it. Every refresh after that asks only for PRs in the list updated since its last refresh (`updated:>=`, two minutes earlier to allow for lag, any state), and adds or updates those without dropping anything; the refresh time recorded is when the request started. Merged and closed PRs therefore stay stored with their state, and the list shows only open ones unless the toolbar's "Show closed and merged" toggle is on (remembered between runs), when they appear muted with a badge. A PR you've reviewed never reappears in the to-review search to say so, so each refresh also checks every to-review PR directly (`nodes(ids:)`) and drops those that are no longer open or no longer request your review; a request to any team keeps a PR there, as team membership isn't checked. Your login for that check is looked up once and stored. If it fails, the stored lists stay up with a banner saying how old they are. To start afresh, quit the app and delete the database (and its `-wal`/`-shm` files):

```sh
rm ~/Library/Application\ Support/Loupe/loupe.sqlite*
```

After each refresh the app looks for each listed repo's local checkout, for diffing PRs locally later. A repo it has no checkout stored for is looked for as a directory with the repo's name (not `<repo>-<branch>` worktree copies) under `~/Development/tamarinworks/`, then `~/Development/GitHub/`, and accepted only if its `origin` is that repo on github.com. Finds are stored in the `localRepo` table; misses aren't, so they're looked for again next refresh. A stored checkout whose directory has gone is dropped and looked for afresh. Each row shows a folder icon when the checkout is known; right-click to reveal it in Finder, or to locate it by hand when it wasn't found. The search roots are `CheckoutResolver.defaultSearchRoots`, overridable through `PullRequestListModel`'s `checkoutSearchRoots`. Git is only ever run read-only against checkouts. To fix a wrong mapping, quit the app and delete its row:

```sh
sqlite3 ~/Library/Application\ Support/Loupe/loupe.sqlite "DELETE FROM localRepo WHERE nameWithOwner = '<owner>/<repo>'"
```

The lists and each opened PR are separate windows grouped as native macOS window tabs, so the tab bar appears once a PR is open. A PR's window is titled `repo #number` (what its tab shows) with the PR's title beside it. Opening a PR that already has a window brings it forward. Keys: ⌘W closes the tab (the lists can be closed too), ⌃Tab / ⌃⇧Tab and "Move Tab to New Window" / "Merge All Windows" come from AppKit in the Window menu; the app adds ⌘⇧[ / ⌘⇧], ⌘1–⌘8 for the Nth tab, ⌘9 for the last, and ⌘T "Show Pull Requests", which reopens the lists if closed. Open PRs and the frontmost one are stored (`openTab` table, `selectedTab` setting) and reopened next launch; a PR with an open window stays stored even after it leaves both lists.

A PR's window shows the PR's header (state, CI, review decision, `head → base`, "Open on GitHub") over its changed files and diff, produced from the repo's local checkout, showing each step: finding the checkout, fetching, diffing. With no checkout known it says so and offers "Locate Checkout…". In the checkout it runs, all without touching branches, the index or the working tree:

```sh
git fetch --no-tags --no-write-fetch-head origin +refs/pull/<N>/head:refs/loupe/pull/<N>/head
git cat-file -e <baseRefOid>^{commit} || git fetch --no-tags --no-write-fetch-head origin <baseRefName>
git merge-base <baseRefOid> <head>
git diff -M <merge-base> <head> -- . ':(exclude,top)vendor' ':(exclude,top)go.sum' ':(exclude,attr:linguist-generated)' ':(exclude,attr:linguist-generated=true)'
git diff --name-only -M <merge-base> <head> -- <the same paths, not excluded>   # counted as hidden
```

Fetches time out after two minutes and other git commands after one; a failure shows git's stderr with a "Try Again" button. Lockfiles git didn't exclude (`yarn.lock` and so on) are hidden by `PathFilter` as before, and the sidebar counts both. The diff is kept in memory per PR, so switching tabs doesn't redo it; when a refresh brings a new head commit, the PR's window produces it again. When each PR's diff was last produced, from which head and merge-base, is stored in `pullRequestDiff` (the diff text isn't). To see where Loupe has fetched to in a checkout:

```sh
git -C <checkout> for-each-ref refs/loupe/
```

Or open a diff file directly. Make a diff to view from PR `<N>` in a local checkout of `<owner>/<repo>`, with vendored code left in (the app hides it itself):

```sh
git -C <checkout> fetch origin refs/pull/<N>/head
git -C <checkout> diff \
  $(git -C <checkout> merge-base <head> <base>) \
  <head> > fixtures-local/<repo>-<N>-full.diff
```

(`fixtures-local/` is gitignored. `<head>` and `<base>` are the PR's `headRefOid` and `baseRefOid` from the API.)

Open the GUI. Clicking a diff row prints its anchor to the terminal, e.g. `clicked go.mod RIGHT 10`:

```sh
swift run Loupe fixtures-local/<repo>-<N>-full.diff
```

Time the diff view headlessly. This uses the largest file whose path contains the optional substring:

```sh
swift run -c release Loupe --bench fixtures-local/<repo>-<N>-full.diff types/types.go
```

I couldn't launch the GUI myself (the sandbox blocks window-server access), so it builds but its on-screen behaviour hasn't been seen: window activation, scrolling, click reporting, the sidebar, the PR list's layout, and its checkout icons and menu, the window tabs and their keys, the title-bar icon, and restoring windows at launch. Opening, focusing, closing and storing open PRs, and producing a PR's diff from a checkout (against real temp git repos with a bare origin exposing `refs/pull/<N>/head`), are covered by tests. The PR list's loading, storage, paging, refresh and error handling are covered by tests, and its paged search query was run against the live API. Rendering, layout, drawing, anchors and copying *are* exercised headlessly by the tests and the bench, using the same `DiffTextView`.

The app icon's source is `Icon/loupe.svg`, a hand-drawn loupe over a cat-octopus silhouette. Without an .app bundle, the app sets it as the Dock icon at launch from `Sources/Loupe/Resources/Loupe.icns`. After editing the SVG, regenerate the icns and the `Icon/preview-*.png` previews (needs `brew install librsvg`; `iconutil` fails inside the agent sandbox), then rebuild:

```sh
Icon/render.sh
```

`swift run` gets a Dock icon but ⌘-Tab shows a generic one, as it reads the icon from an app bundle. To build a release `.app` (ad-hoc signed, under `.build/`) and open it:

```sh
./start.sh                 # debug build of Loupe.app, then opens it
./start.sh release         # same with an optimised build
sh Scripts/bundle.sh && open .build/Loupe.app   # the two steps separately
```

## Snapshots

The app can draw its own windows to PNGs, title bar, toolbar and tab bar included, without screen-recording permission. The Debug menu has "Save Snapshot of Window…" (⌥⌘S) and "Snapshot All Windows to Desktop".

With `LOUPE_SNAPSHOT_DIR` set, the app waits until the lists have refreshed and each open PR's diff is ready or has failed (at most 20 seconds), writes `<index>-<title>.png` per window into that directory, prints their paths and quits. `LOUPE_DATABASE` points it at another database. `open` doesn't pass the environment on, so run the bundle's executable directly:

```sh
Scripts/snapshot.sh /tmp/loupe-snaps   # builds the bundle, runs it as below

# the same by hand, against a copy of the database
sh Scripts/bundle.sh
cp ~/Library/Application\ Support/Loupe/loupe.sqlite* /tmp/loupe-db/
LOUPE_DATABASE=/tmp/loupe-db/loupe.sqlite LOUPE_SNAPSHOT_DIR=/tmp/loupe-snaps .build/Loupe.app/Contents/MacOS/Loupe
```

The windows briefly show on screen while it runs, each tab brought forward in turn so it's drawn.

## What the probe showed

Details are in `probe/NOTES.md`. In short:

- A review thread's `line` + `diffSide` is a **file line number** on the head (RIGHT) or base (LEFT) side, not a diff position. That's the same `(path, side, line)` the diff view reports on click, so comment anchoring lines up. A test checks this against a real `diffHunk`.
- **Outdated threads have `line: null`**: only `originalLine` is set (10 of 21 recent marmot threads). They need the diff of the original commit, or a separate list.
- `startLine` is `null` on some single-line comments and equal to `line` on others.
- **CircleCI reports as legacy `StatusContext`s**, not `CheckRun`s (only Codecov uses check runs). The two have different field names, so CI status has to handle both.
- **`files` includes vendored code and pages at 100.** On atrium#2912, 98 of the first 100 entries were `vendor/` (741 total); the 4 real files were on later pages.
- `mergeable` is `UNKNOWN` until GitHub computes it (and always on merged PRs). `viewerViewedState` is there for syncing "viewed".
- The inbox is a single `search` query; `reviewDecision` and `isDraft` come back inline.
- Excluding `':!vendor' ':!go.sum'` from `git diff` worked: 741 files went down to 4, removing 736 vendor files and `go.sum`. For merged PRs, use `baseRefOid` for the merge-base, not `origin/master`, or the diff comes out empty. Don't rely on `FETCH_HEAD` in a shared checkout: another fetch overwrote it during the probe.

## Diff view approach

- `DiffParser` (pure Swift) turns `git diff` output into files → hunks → lines. Each line is `.context(old:new:)`, `.addition(new:)` or `.deletion(old:)`, so line numbers are never optional where they exist. It handles renames, copies (the user's git config has `diff.renames=copies`), deletions, pure renames with no hunks, "\ No newline", and CRLF (it splits on LF bytes, because Swift treats `"\r\n"` as one `Character`). `PathFilter` hides `vendor/`, `node_modules/` and lockfiles, and the sidebar shows how many it hid.
- `RenderedDiff` turns one file into a single `NSAttributedString`. The gutter (old/new numbers and the `+`/`-` marker) is inline text, tagged with an attribute so copying a selection yields plain code. Each row is tagged with its kind, and an array of row start offsets maps a click to a row (binary search) and from the row to its `DiffAnchor`.
- `DiffTextView` is an `NSTextView` subclass: non-editable, selectable, with a find bar. It uses TextKit 1 with **non-contiguous layout** and no line wrapping. A small `NSLayoutManager` subclass paints full-width row backgrounds. A single click (not a drag-select) reports the anchor.
- `DiffView` is the `NSViewRepresentable` wrapper; the `App` is a `NavigationSplitView` with the file list on the left.

### Measured performance

Release build on an Apple M4, measured with `--bench`:

| | 92 rows | 5,355 rows | 45,919 rows |
|---|---|---|---|
| build attributed string | 0.3ms | 15ms | 128ms |
| set text storage | 4.6ms | 7.8ms | 13ms |
| lay out first screen | 1.1ms | 1.2ms | 1.6ms |
| draw a screen (first / middle) | 6.7 / 5.5ms | 8.8 / 12ms | 9.1 / 38ms |
| lay out whole file (only on jump-to-end) | ~0 | 53ms | 706ms |

Parsing the whole 260k-line, 741-file diff took 53ms.

So a 5k-line file opens in about 33ms, comfortably fast. A 46k-line file takes about 150ms to open, then is smooth, apart from a one-off ~0.7s if you jump straight to the end.

## What was hard

- **Painting full-width row backgrounds without losing lazy layout.** The obvious place, `NSTextView.drawBackground(in:)` plus `glyphRange(forBoundingRect:)`, silently forced layout of the whole file on first paint: 61ms at 5k rows and 500ms at 46k, against 9ms once fixed. Moving the painting into `NSLayoutManager.drawBackground(forGlyphRange:at:)`, which only sees glyphs already laid out, fixed it. A test samples pixels to check the backgrounds are painted, and fails if they aren't.
- **Swift 6 concurrency with AppKit.** `NSLayoutManager` isn't `@MainActor`, so its overrides can't touch the view's state. Filling to the graphics context's clip bounds avoided needing the view at all.
- Merged-PR merge-bases and `FETCH_HEAD` races, covered above.

## What I'd change in the plan

1. **Get the diff and file list from git, not the API.** `files` pages at 100 and is dominated by vendored code, and the API's patch text isn't in GraphQL anyway. Fetch `refs/pull/N/head`, then diff `headRefOid` against the merge-base with `baseRefOid`, in a bare cache clone the app owns rather than the user's working checkouts. Use GraphQL for metadata, threads, CI and the inbox.
2. **Inline comment rendering is now the riskiest part**, and the next spike. A single `NSTextView` has no natural way to put a block between two rows. Options: a text attachment with a view provider, TextKit 2 custom layout fragments, or a stack of per-hunk text views with comment views between them. The last is simplest, but makes selection across hunks harder.
3. **Outdated threads need their own path.** Either fetch `originalCommit` and show that diff, or list them separately.
4. **Build the attributed string off the main thread** (or collapse files over ~10k rows by default), so a huge file doesn't stall the UI for 130ms.
5. Small things for later: the find bar also matches gutter digits; a "\ No newline" marker isn't drawn yet; quoted paths (filenames with unusual characters) aren't unquoted; there's no toggle to show hidden vendored files.

## Layout

- `Sources/LoupeCore/`: `DiffModel.swift`, `DiffParser.swift`, `DiffRenderer.swift` (attributed string and anchors), `DiffTextView.swift`
- `Sources/LoupeModel/`: `PullRequest.swift` (the PR summary and list types shared by the targets below)
- `Sources/LoupeGitHub/`: `GitHubClient.swift` (GraphQL over `URLSession`, pluggable transport; pages each search), `GitHubCLI.swift` (`gh auth token`), `PullRequest.swift` (response decoding)
- `Sources/LoupeStore/`: `PullRequestStore.swift` (GRDB: one row per PR keyed by node id, list membership and per-list refresh times, set up by migrations), `LocalRepoStore.swift` (each repo's local checkout), `TabStore.swift` (open tabs and when each PR's diff was produced)
- `Sources/LoupeGit/`: `CheckoutResolver.swift` (finds, verifies and stores checkouts), `GitHubRemote.swift` (matches an origin URL to `owner/name`), `Git.swift` (runs git with a timeout), `PullRequestDiffer.swift` (fetches a PR into `refs/loupe/` and diffs it from its merge-base)
- `Sources/LoupeInbox/`: `PullRequestListModel.swift` (start-screen state wiring GitHub to the store; `onOpen` is where choosing a PR goes), `TabsModel.swift` (the open PRs and which is frontmost), `PullRequestTab.swift` (one open PR's diff, from checkout to ready)
- `Sources/Loupe/`: `Entry.swift` (PR list, diff file or `--bench`), `App.swift`, `WindowTabs.swift` (the lists and PR windows, grouping them as native tabs, restoring them, and the tab keys), `PullRequestView.swift` (a PR's window), `PullRequestListView.swift`, `DiffView.swift`, `Bench.swift`
- `Tests/LoupeTests/`: tests, with fixtures from atrium#2912 (the 4-file diff, and edge cases cut from the full diff)
- `Tests/LoupeInboxTests/`: PR list tests against an in-memory GitHub that matches searches (author, review request, `is:open`, `updated:>=`) and review-request lookups against the PRs in `probe/pr-list.json`, checking the shape of each search it receives, plus `probe/graphql-error.json`; checkout tests against real `git init` repos in temp search roots; diff and tab tests against `FakeRepository`, a temp bare origin exposing `refs/pull/<N>/head` with a contributor clone and a reviewer checkout
- `probe/`: GraphQL queries, raw responses and `NOTES.md`; `incremental-query.graphql` → `incremental.json` confirmed the `updated:>=` search, PR `state`/`mergedAt`/`closedAt`, `viewer { login }` and the `reviewRequests` shape
