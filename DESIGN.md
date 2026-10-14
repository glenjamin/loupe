# Loupe: goals and design decisions

Loupe is a native macOS app for reviewing GitHub pull requests. It exists because reviewing on github.com is slow for repos that vendor dependencies, and because a local app can lean on local checkouts in ways a web page can't.

## Goals

- Review PRs faster than on github.com, for one person, on a Mac.
- Vendored and generated files never get in the way: excluded from diffs by default, not merely collapsed.
- The app is usable the moment it opens, with whatever it already knows, and refreshes in the background.
- Keyboard-driven review once the basics are in place.

## Decisions

Each entry says what we chose and why, so a later change can be made knowingly. Add new ones at the end; don't rewrite old ones, note the reversal instead.

### Native app, not a browser extension

A Firefox extension over github.com would get commenting and review submission for free, but it rides GitHub's React DOM, which changes often, so it would be a maintenance tax with a low ceiling. A native app can use local checkouts, cache locally, and own its layout and keyboard model.

Complement, not alternative: a `.gitattributes` line of `vendor/** linguist-generated=true` in a repo collapses vendored files on github.com for everyone. GitHub's docs say only `linguist-generated` affects diffs; `linguist-vendored` only affects language stats.

### SwiftUI + AppKit, built with SwiftPM, no Xcode required

The machine has Command Line Tools only. SwiftPM with an executable target links AppKit and SwiftUI fine, so there is no `.xcodeproj`. Targets are split so that pure logic (`LoupeCore`, `LoupeModel`, `LoupeStore`) has no AppKit dependency and is testable headlessly.

### Diffs come from local checkouts only, never from the API

`git diff` against the checkout gives full-file context, honours pathspec exclusions (`':!vendor' ':!go.sum'`), has no rate limit and no file-count cap. The API's PR file list on a typical Go repo was 98% `vendor/` (741 files, of which 4 were real), and the REST files endpoint omits patches for large files and caps at 3,000 files.

Consequence: a PR can only be reviewed in Loupe when its repo is checked out locally. The app tracks checkout locations (see below). Checkouts are shared with other tools, so Loupe never touches branches, the index or the working tree. The one write it makes is fetching the PR head into its own ref namespace, `refs/loupe/pull/<N>/head`, so the objects stay reachable and nothing races over `FETCH_HEAD`.

For merged PRs, use the API's `baseRefOid` for the merge-base; the local default branch has moved on and the diff comes out empty. Don't rely on `FETCH_HEAD` in a shared checkout; another fetch can overwrite it.

### GitHub GraphQL for metadata; REST only where it is the better fit

One GraphQL search request returns a PR list with CI rollup, review decision, branches and author inline. The REST search endpoint returns issue-shaped objects and needs two or three more requests per PR for the same fields, and has its own 30-per-minute limit. REST is still the right tool for the whole-PR diff (`Accept: application/vnd.github.diff`, if ever needed), `POST /markdown` for GitHub-faithful rendering, and `GET /notifications`.

Known shapes, from `probe/`: CircleCI reports as legacy `StatusContext`s, not `CheckRun`s (only Codecov uses check runs), so CI handling must cover both. A review thread's `line` plus `diffSide` is a file line number, not a diff position; outdated threads have `line: null` and only `originalLine`.

### Auth is borrowed from the `gh` CLI

The app shells out to `gh auth token` per request and never stores the token. Good enough for a personal tool; a Device Flow OAuth app is the path if it's ever shared.

### A local SQLite copy is what the UI shows; GitHub is synced into it

Storage is SQLite via GRDB (migrations, record types, `ValueObservation` for live UI updates), at `~/Library/Application Support/Loupe/loupe.sqlite`. Launch shows stored rows instantly with a "refreshed N ago" label; refresh runs in the background. A failed refresh keeps the stored rows and shows a banner, never a blank list.

Rows have real columns per field, not a JSON blob, so the data is queryable. List membership (authored by me, review requested) is tracked separately from the PR row, since one PR can be in both.

DuckDB was considered and rejected for the app itself: the workload is small row-at-a-time upserts, which is SQLite's strength, and the DuckDB Swift binding lacks migrations and observation. For analytics over the history, point DuckDB's `sqlite` extension at the same file.

### Refresh is incremental after the first load

First load of a list uses `is:open`, paged to exhaustion, and reconciles fully. Every refresh after that drops `is:open` and asks for `updated:>=<last sync minus a small overlap>`, so merges and closes arrive as state changes rather than as absences. The UI filters to open PRs by default with a toggle to show closed and merged.

Fulfilled review requests are the gap: a PR you have reviewed stops matching `review-requested:@me` and never comes back to say so. A `nodes(ids:)` check over the to-review column catches those. Team-level requests are kept, since team membership isn't cheaply knowable.

### Checkout locations live in the database and are discovered automatically

A `localRepo` table maps `owner/name` to an absolute path. Unknown repos are looked up by exact directory name under `~/Development/tamarinworks/` then `~/Development/GitHub/`, accepted only when the directory is a top-level git repo whose `origin` points at that repo on github.com. Misses are not stored, so they retry. A stored path whose directory has gone is dropped and re-resolved. The search roots are a list in the model so they can become a setting.

### The diff view is one `NSTextView` with lazy layout

One attributed string per file, TextKit 1 with non-contiguous layout and no wrapping; full-width row backgrounds are painted in the layout manager, not the view, because doing it in the view silently forced layout of the whole file. A 46k-row file opens in about 150ms. Clicking a row yields `(path, side, line)`, the same anchor GraphQL review threads use.

### PRs open in tabs inside one window

Tab 0 is the PR lists and cannot be closed; each opened PR gets a closeable tab with browser-style keys (⌘W, ⌘1–9, ⌘⇧[ and ⌘⇧], ⌃Tab). Open tabs persist across launches. This keeps several reviews in flight without a window per PR.

### The window's chrome is the same whichever tab is showing

The title is always "Loupe", with the selected tab in the subtitle, and one unified toolbar is declared at the window level with items that change per tab. A toolbar or title declared by a tab's own view would come and go with the tab, resizing the title bar on every switch.

### PRs open as native window tabs, replacing the custom tab strip

The PR lists are one window and each opened PR is its own window, all grouped as AppKit window tabs (the tabs Safari, Finder and Terminal use) through a shared `tabbingIdentifier` and `tabbingMode = .preferred`. This replaces the SwiftUI tab strip above: two custom attempts looked wrong and weren't clickable on the user's machine, while AppKit's tabs look right and give ⌘W, ⌃Tab, "Move Tab to New Window" and "Merge All Windows" for free. The app adds only ⌘1–⌘9, ⌘⇧[ / ⌘⇧] and "Show Pull Requests" (⌘T), which reopens the lists if they were closed. Opening a PR that already has a window brings it forward. The open PRs and the frontmost one are stored and reopened at launch, so SwiftUI's own window restoration is turned off to avoid duplicates.

### Each window declares its own title and toolbar

Every window has the tall unified title bar and toolbar, so tabs match in height. The lists are titled "Pull Requests"; a PR is titled `repo #number`, which its tab shows, with the PR's title as the subtitle. The app icon sits beside each title where a document's icon would. This supersedes the single "Loupe" title with a per-tab subtitle, which only made sense while the tabs were one window.

### Producing a PR's diff leaves the checkout's other state alone

Fetches pass `--no-tags` and `--no-write-fetch-head`, so the only things they change are `refs/loupe/pull/<N>/head` and, when the base commit is missing, the base branch's remote-tracking ref. Hidden paths are excluded with pathspecs, `linguist-generated` ones through `:(attr:…)` magic against the checkout's own `.gitattributes`, and a second `--name-only` diff over the same pathspecs lists what was hidden, so the count stays honest. An open tab keeps its PR row stored after the PR leaves both lists, so a tab can always be restored. A list holding rows stored before commit oids were fetched gets a full load rather than an incremental one, which fills them in.

### Long diff rows wrap with a hanging indent

Rows soft-wrap at the view's width by default, with a View menu toggle. Each row's paragraph style indents continuation lines by the gutter's width, so wrapped code lines up under the code rather than under the line numbers, as on GitHub. Wrapping stays within TextKit 1's non-contiguous layout, so opening a large file costs the same either way; row backgrounds are painted per visual line and clicks map by character offset, so neither needed changing.

### Code is highlighted with tree-sitter, parsed per hunk

Each hunk's new side and old side are parsed with the file's tree-sitter grammar and coloured from the grammar's own `highlights.scm` with Primer's palette, which is how GitHub highlights diffs, partial snippets and all. Grammars come from their upstream SwiftPM packages through ChimeHQ's SwiftTreeSitter, and a file in an unknown language stays plain. Highlightr was ruled out because it runs highlight.js's regex grammars in JavaScriptCore, a cruder approach than GitHub's; Neon was ruled out because it manages incremental re-highlighting for an editor, and this is a static render. Colours go into the layout manager's temporary attributes, not the text storage, because adding tens of thousands of colour runs to a large storage costs several times as much; files over 5,000 rows paint plain first and take their colours from a background parse.

### Grammars come from CodeEditLanguages, not one upstream package each

Grammars and their highlight queries come from CodeEditLanguages, a single package that bundles about 40 prebuilt grammars. This replaces ten upstream grammar packages: each upstream manifest is maintained separately, several of their later releases fail to link under SwiftPM (so CSS, JavaScript and YAML were held at old tags and Swift at a special one), and every new language meant another dependency. One package gives SQL, Dockerfile, Markdown, Python, TOML, `go.mod` and more for free, with its own detection by extension and file name. The cost is a slightly slower prebuilt Go grammar, and a package that hasn't tagged a release since late 2024; Makefile and HCL still have no grammar there.

### Windows are AppKit's, not SwiftUI scenes

The lists window and each PR's window are `NSWindow`s made and tracked by `WindowManager`, hosting the SwiftUI views in `NSHostingController`s that carry their titles and toolbars into the window. SwiftUI keeps only the menu bar, hung on a `Settings` scene that opens no window. As scenes, the windows fought the app at every turn: SwiftUI's window controller handles `newWindowForTab:`, so the tab bar always showed a "+" that made stray windows SwiftUI then reused; its restoration duplicated the windows the store reopens; and a shared frame autosave name could be held by only one of its windows. Owning the windows removes the "+" (nothing implements `newWindowForTab:`), lets the store be the only restoration, and lets the lists window keep a frame autosave name that PR windows outside a tab group start from. A PR window joins the lists' tab group explicitly, in the stored order. As the app quits SwiftUI still closes every window, so the manager stops forgetting PRs once termination begins.

### Languages and hidden files follow GitHub Linguist's data

Which grammar a path gets, and which paths are hidden as vendored, come from GitHub Linguist's own `languages.yml`, `vendor.yml` and `documentation.yml`, vendored from a tagged release and refreshed by `Scripts/update-linguist.sh`. Linguist is what GitHub uses, so Loupe highlights and hides the same files GitHub does, and picks up new languages and vendoring rules without hand-maintained lists. `.gitattributes` `linguist-*` attributes override it either way, as on GitHub. The YAML is converted to JSON by the script so the app needs no YAML dependency. Linguist's content heuristics aren't run; an ambiguous extension takes the first of its languages that has a grammar.

### The diff view reads like GitHub's

Rows are 12pt on a 20pt line, with the code padded from the edges and its column set by a tab stop after an inline gutter: right-aligned old and new numbers and a `+`/`-` marker, on a darker tint of the row. The gutter stays inline text, tagged so copies strip it, so clicks, find and copying keep working on one string. Hunk headers mute the line ranges and keep the function context in the text colour. Within a run of deletions followed by as many additions, each pair of lines is diffed by token and the changed words are tinted more strongly, as GitHub does; pairs sharing under 30% of their tokens, lines too long to diff cheaply, and changes only to whitespace (gofmt realigning a block) get no emphasis. This happens while building the attributed string, so it's measured with it. Each file sits in a bordered box under a header bar with its path and counts.

### Open PRs learn of changes from notifications, and offer a reload

An open PR's window notices when the PR changes on GitHub and says so in a banner with a Reload button, as github.com does, rather than replacing the diff under the reader or waiting for the lists' three-minute refresh. This reverses re-diffing automatically when a refresh moves the PR's head: a reviewer partway through a diff keeps their place until they choose to move on.

The signal is GitHub's notifications API, polled with `If-Modified-Since`: a 304 costs no rate limit, so an idle poll is free, and GitHub's `X-Poll-Interval` (60 seconds) sets the pace, which is latency enough for review. Webhooks would be immediate but need admin rights on each repo and a process reachable from GitHub to receive them. Notifications only say which PRs to look at; the open PRs they name are then fetched in one `nodes(ids:)` query and stored, so the window compares stored rows and doesn't care which route an update came by. That lookup also fetches commit, comment and review thread counts, which the list searches don't: on a full page of 100 results they took the search to GitHub's time limit and it returned 502s, so a search keeps the counts last looked up. A token that can't read notifications falls back to that query over every open PR each minute. Notifications only cover threads the user participates in, which is every PR they've authored or been asked to review, and so nearly every PR Loupe opens. Whether a push on its own updates a notification hasn't been confirmed; if not, the lists' refresh still brings a moved head to the banner within a few minutes.

## Not yet decided

- How review threads and comments render inline in the diff, and how outdated threads (no current line) are shown. The next spike.
- Markdown rendering: `POST /markdown` into a web view versus a native renderer.
- Review submission: pending review via `addPullRequestReview`, threads via `addPullRequestReviewThread`, then `submitPullRequestReview`.
