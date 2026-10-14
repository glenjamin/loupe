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

### The lists tab can't be closed and stays first

The lists are the app's home, so their window has no close button and refuses closing, including the tab bar's "Close Other Tabs", which asks the window's delegate rather than checking the button. With no SwiftUI window scene there is no File menu of SwiftUI's, so the app supplies "Close Tab" (⌘W) and "Close All" (⌥⌘W); both pass over the lists rather than beep at them. "Merge All Windows" run from a PR's window would put the lists last, so they are moved back to the first tab.

### Linguist's vendor list is narrowed for review

Linguist's `vendor.yml` serves language statistics, so it also names things a reviewer must see: `testdata/`, test fixtures, `.github/`, git and editor config, `Jenkinsfile`, `.d.ts` declarations. GitHub itself never hides vendored paths in a diff. Loupe hides dependency trees, minified bundles, lockfiles and generated files, and keeps the rest; the kept patterns are listed verbatim in `PathFilter` and a test checks each still exists in Linguist's list, so a Linguist update that renames one is noticed rather than silently hiding files.

### Snapshots are how anyone sees the UI without a screen

`Scripts/snapshot.sh` builds the app, launches it as an invisible accessory process with its windows off every screen, waits for lists and diffs to load, writes a PNG per window and quits. Agents can't launch a GUI from the sandbox, so this is the only sanctioned way to run the app other than `--bench`; launching it any other way opens real windows on the user's screens.

### The conversation tab is a web view of GitHub's own HTML

A PR view has GitHub-style segmented tabs, Conversation and Files changed, inside the window rather than a second tier of native tabs. The conversation is one web view built from the `bodyHTML` fields GraphQL returns for the description, comments and reviews, so mentions, code blocks, tables, task lists and emoji render exactly as on github.com with no markdown engine of our own. The diff stays native. The HTML and its styling are ours to change later. Known limit: images attached to private repos need a browser session and may not load.

### Viewed files sync with GitHub, and pulling past a file's end marks it viewed

A file's "Viewed" state is GitHub's own `viewerViewedState`, read and written through GraphQL (`files { path viewerViewedState }` paged to the end, as vendored files swamp the list; `markFileAsViewed` and `unmarkFileAsViewed`), so a review started in Loupe carries on at github.com and back. It's stored per PR and path so a tab shows it at once, and fetched afresh when a tab opens and on Reload. A change shows immediately and is put back if GitHub refuses it. `DISMISSED`, a viewed file changed by a later push, is flagged in the sidebar and counts as not viewed when moving on.

Moving on is a gesture like pull-to-refresh at the bottom: pulling past the end of a file's diff reveals an indicator that fills over about 80pt, gives a haptic tap when full, and letting go then marks the file viewed and shows the next file not viewed, wrapping to the top. Reaching the end is the moment a reviewer has finished a file, so the gesture costs nothing extra and needs no reach for a checkbox. Only a live drag counts, never momentum bouncing off the end, so a fling through a file can't mark it by accident; the threshold logic is a pure type, `OverscrollTrigger`, since scroll events can't be driven headlessly. ⌘↓ and `]` do the same from the keyboard and ⇧V toggles the shown file. The bare keys are handled by a key monitor that steps aside while text can be typed, rather than as menu shortcuts, which would take them from every text field.

### Each file's diff ends in a footer that moves on; pulling past it is a shortcut

Every PR file's diff ends in a footer inside the scrolled content, a bar like the file's header with a button that marks the file reviewed and shows the next one not reviewed. This revises the gesture above as the only way: a mouse wheel never pulls past the end, and on a trackpad the stretch had to be held while 80pt filled, so the user found the control hard to reach at all. The footer is reached by ordinary scrolling and clicked like any button; a file shorter than the view has it straight after its last row. The pull stays as a shortcut, now over about 40pt, and fills the footer itself rather than a separate indicator that existed only mid-stretch. The footer lives in the scroll view's clip view, placed in the document's coordinates, with a bottom content inset to make room, so the text view stays the document view and its wrapping and lazy layout are untouched.

### The conversation tab: replies come from threads, and the web view is kept

An addendum to the conversation tab's decision. GitHub's timeline omits reviews that only reply in threads, so thread replies are fetched with `reviewThreads` (bodies and authors) and shown inside the thread under the review that started it, as github.com does; a review's own comments give each thread's path, lines and diff hunk. The conversation is stored in tables per kind of row (timeline items, review comments, threads, thread comments, checks), keyed by PR and item id, and fetched on opening a PR's tab and on Reload rather than when the tab is first chosen, so it's usually there by then. The web view is made the first time Conversation is chosen and kept hidden behind the files after that, as is the diff behind it, so neither loses its place. The page is assembled in Swift rather than by a script in the page, so it runs with no script at all under a Content-Security-Policy that loads only GitHub's images. ⌃1 and ⌃2 switch, since ⌘1–⌘9 pick window tabs.

### Hidden files are listed, and diffed only when shown

Vendored, lockfile and generated files stay out of the main `git diff`, as a vendor tree can be enormous and would slow every diff, but they are listed under their own "Vendored, lockfiles and generated" section below the files to review, as a reviewer sometimes needs to check a dependency bump or a regenerated file. This revises the goal of excluding them rather than merely collapsing them: they still cost nothing until opened. Their change kinds come from the same `--name-status` listing that decides what's hidden, so they cost no extra git run. Each one is diffed on its own, by literal pathspec (with a rename's old path, so the rename is kept), only when selected, and kept in memory. Until then its row says "added", "modified" and so on in place of line counts, rather than running `--numstat` over a whole vendor tree for counts nobody may look at. Their reviewed state is GitHub's, as for any file, but moving on and the reviewed count pass over them, so the review keys never walk a reviewer through vendored code.

### A commit picker shows one commit's changes

As on github.com's "Files changed", a popup above the file list picks "All changes" or one of the PR's commits, oldest first. The commits come from `git log <merge-base>..<head>` in the checkout, not from GitHub, so they always match the diff shown. A commit's changes are from its first parent, or the empty tree for a root commit, and are diffed when first picked and kept per tab; a range names its commits, so a cached diff can never go stale. Reloading goes back to "All changes". Reviewed state stays per path, as GitHub keeps it, whatever is shown.

### One window with the app's own tab strip, replacing native window tabs

This reverses "PRs open as native window tabs, replacing the custom tab strip" and "Windows are AppKit's, not SwiftUI scenes" as far as they make a window per PR, and relaxes "The lists tab can't be closed and stays first". The user wanted the lists to be a button that is always there rather than a tab, and tabs two rows high with the PR's title under `repo #number`, which native window tabs can't do. So there is one window, and directly under its unified title bar sits a strip of our own: a "Pull Requests" button first, then a tab per open PR. It's in the window's content rather than the title bar, where both earlier SwiftUI strips lost their clicks to window dragging, and it's AppKit views rather than SwiftUI so a click always lands; a snapshot-run hook clicks it through the window to prove so. Each PR's view is made when its tab is first shown and then kept, hidden, so tabs keep their diffs, scroll positions and web views as separate windows did. The window's title and toolbar still come from SwiftUI's scene bridging, from one SwiftUI view at the window's root that wraps the AppKit strip and content and declares the shown item's title and toolbar, since only the window's root hosting controller bridges them. ⌃Tab, ⌘W and moving between tabs are now the app's own; "Move Tab to New Window", "Merge All Windows", dragging tabs to reorder them and seeing two PRs side by side in separate windows are lost. Closing the shown tab shows its neighbour, as native tabs did; a middle click on a tab closes it, as in browsers; and the window itself has no close button, as the lists' window had none.

### Pulling past the footer is real scrolling, fires mid-drag, and fills the button

This revises how the pull shortcut feels; the user found it still too hard and too slow. Below the footer is some slack, about the footer's height again, added to the bottom content inset, so pulling past the footer is ordinary unresisted scrolling instead of AppKit's rubber band, which resists hard. Progress is how far into the slack the view has scrolled, and the slack is there whatever the file's length, so a file shorter than the view can still be pulled. It fires the moment a live drag crosses the threshold, now about 32pt, with the haptic tap then, rather than waiting for the fingers to lift. Momentum still never fills or fires it, so a flick through a short file can't skip it. Once fired it stays spent until the view is back out of the slack, and the rest of that gesture, momentum included, is dropped so it doesn't scroll the next file. With no rubber band to spring back, the view glides back out of the slack once scrolling stops with the fingers lifted, however it got there. The progress fills the footer's button itself, inside its rounded bezel, accent while filling and green as it fires, rather than a band across the whole footer; the button has its own style, drawn like a large push button, to make that possible. The footer's button was also unclickable: a clip view hit-tests only within its document view, and the footer sits below the text view in the inset, so the clip view is a subclass that hit-tests its other subviews too.

Addendum: like pull-to-refresh, the slack holds a caption saying what the pull will do, worded for the case at hand (moving on, the last file, or already reviewed). It fades in with a live drag's progress, says "Marked reviewed" as it fires, and shows nothing at rest or while the view settles back from a pull let go short.

### A checkout matches a repo by any of its remotes

A fork's checkout has the fork as `origin` and the repo it came from as another remote, often `upstream`, and PRs to that repo were reported as having no checkout. So a checkout now matches a repo when any of its remotes points at it on github.com, whether found by name under the search roots or located by hand. When one directory per search root is a candidate, one whose `origin` is the repo wins over a fork's, so a plain clone is preferred. Fetching a PR uses the checkout's remote for the PR's repo (`origin` if several match) for both the PR's ref and the base's remote-tracking branch, still writing only under `refs/loupe/`. The remote is looked up again at fetch time with one git call rather than stored beside the path, so the store is unchanged and a remote renamed since stays right. Remote URLs are read as configured, before any `insteadOf` rewrite, since that's what names the repo.

### Checks show as a bare glyph, and hovering lists each check

A PR's overall check state is a plain coloured tick, cross, clock or question mark, with no filled circle, as the filled symbols were the loudest thing in a row. Hovering it gives a native tooltip like GitHub's checks popover: a summary line ("2 of 5 checks failed"), then a line per check with a glyph, its name and its description (a check run's title, where Codecov puts its coverage), failing first, then pending, then the rest in GitHub's order. The text is built by a pure function in `LoupeModel` so it's tested without a UI.

The per-check contexts come from a separate lookup by id, not from the list searches. Measured against the real API on a full page of 100 open PRs: the author search took about 7.5s without contexts and 8.4–9.6s with them, and a denser 100-PR search went from about 9s to GitHub's 502 at about 11s in three tries of four, which is the time limit the activity counts already hit. A lookup of only id, rollup state and contexts takes about 2.5s per 50 PRs and 4–5.5s per 100, so it runs after each list refresh in batches of 50, over every open listed PR. Every one is asked about because a check finishing doesn't change a PR's update time (19 of 44 of the author's PRs had a check finish after it), so the searches for changes never report it; the rollup state is taken from the same lookup, so the glyph and its tooltip agree. The contexts are stored per PR in their own table and replaced on each lookup, so the tooltip works from the stored copy; until the first lookup the tooltip only names the overall state. The refresh counts as loading until the checks are in. Only the first 50 contexts of a commit are fetched.

### Conflicts show as a badge, from the same lookup by id as checks

A PR whose branch conflicts with its base gets a quiet "Conflicts" badge beside its state badge, in the lists and in the PR header; nothing shows for a clean merge or while GitHub is still working it out. The state is GitHub's `mergeable`, which GitHub computes lazily in the background and answers `UNKNOWN` until it has, so a freshly pushed PR may show nothing until a later refresh.

It's asked for in the lookup by id that fetches checks after each refresh, not in the searches. Measured on a full page of 100: adding it to the author search took it from about 7.5s to 8.5–9.5s, the denser 100-PR search hit a 502 again, and 67 of the 100 came back `UNKNOWN`. In the lookup it raised a batch of 50 from about 2.6s to 3.6–4.9s, within the limit, and answered for all 50 there, though a lookup can still meet `UNKNOWN` on a PR GitHub hasn't got to. The searches and the by-id row lookup leave the stored value alone, so it's only replaced by the next status lookup.

### PRs open on the Conversation tab

A PR's tab now opens on Conversation rather than Files changed, reversing the earlier default. The description and the discussion so far say what a change is for and what's still open, which is what to know before reading its diff, as github.com's own default page assumes. The tab shown is still kept per PR while the window lives, so switching to Files changed sticks.

### Hidden files show their line counts from the start

Each hidden file's additions and deletions come from `git diff --numstat` over the paths hiding them, run beside the main diff, so the hidden section shows `+N -M` like the files to review without producing their diffs. On atrium vendor bumps of 1,000 to 2,400 files it took about 80ms. A row still says added, deleted or renamed, which the counts alone don't, and a binary file says so rather than `+0 -0`.

### Reviewers show in the header on the viewer's own PRs, and more can be asked there

On a PR the viewer wrote, the header's right side lists its reviewers as github.com's sidebar does: everyone asked and not yet answered, then everyone else's latest review (approved, changes requested, commented or dismissed), each with a plain symbol rather than a filled badge so the header stays quiet. Someone asked again after reviewing shows as asked. The author's own reviews, which are their replies to threads, aren't listed, nor is an unsubmitted one. Two columns of up to three rows fit beside the title; beyond that the last place says how many more, with their names in its tooltip. The data comes with the conversation (`reviewRequests` and `latestReviews`), is stored with it and shown from the store at once, so it refreshes when the conversation does: on opening the PR and on Reload.

A button there opens a search of the repo's assignable people and, for an organisation's repo, its teams. They're two queries, so a token that can't read teams still finds people, and that failure isn't shown. Choosing someone calls `requestReviews` with `union: true`, so others already asked stay asked; the reviewer shows as asked straight away, the conversation is fetched again once GitHub agrees, and if it refuses they're taken off and the reason shows in the popover (or, once it's closed, as a warning symbol beside the reviewers). Anyone who has reviewed has a re-request button using the same call, as on github.com. Requests aren't queued or retried: asking someone notifies them, so a failed request is left for the viewer to make again.

Whether the PR is the viewer's is decided by its author's login against the viewer's, which the lists store; a tab looks it up itself if nothing has yet. On anyone else's PR the place is left empty, kept for the approve and request-changes controls that will come with submitting reviews.

### Markdown files can be read rendered, by GitHub's own renderer

A PR's file that Linguist takes for Markdown has a "Source | Rendered" toggle in its header, Source by default. Rendered shows the file at the head of the shown changes (the whole PR or the picked commit), or for a deleted file at their base, read from the checkout with `git show <oid>:<path>` and rendered by GitHub's `POST /markdown` in `gfm` mode with the repo as context, so it reads as on github.com without a markdown engine of our own, as the conversation does. It's shown in a web view with the conversation's template, stylesheet and Content-Security-Policy (no scripts, only GitHub's images), and links open in the browser. Relative links resolve against the file's directory on github.com at that commit, which suits links to other files; relative images then point at an HTML page and don't load, as private repos' images wouldn't anyway. `gfm` mode renders a soft line break as `<br>`, as comments show it, so the file layout hides `<br>` inside paragraphs, which a file view on github.com shows as a space; an explicit hard break is lost with them. `markdown` mode was rejected as it drops task lists and the table markup GitHub uses. Each rendering is kept per file and commit while the tab lives, so toggling back is instant, and the toggle's choice is kept per path. The rendering covers the diff rather than replacing it, so the diff keeps its scroll position; the review footer is the diff's, so moving on from a rendered file is by the keys or the header's checkbox. Change highlighting within the rendered view, GitHub's rich diff, isn't attempted: it would mean diffing two renderings' DOMs.

### Web views stay in GitHub's light theme

The conversation tab and rendered markdown files use GitHub's own HTML, which carries dark-theme variants, and the page's stylesheet had a dark palette behind `prefers-color-scheme: dark`, so both followed the system appearance. The user prefers reading them in GitHub's light theme, so the stylesheet keeps only the light palette and the web view's appearance is pinned to aqua, which is where WebKit takes `prefers-color-scheme` from. The native diff and chrome still follow the system.

### Wrapped rows hang two columns in from the code

An addendum to "Long diff rows wrap with a hanging indent": a continuation that started exactly on the code column was easy to read as a new line, so wrapped lines now hang two character widths further in, as editors do.

### The viewer's own PR descriptions are edited as markdown, starting from GitHub's copy

On a PR the viewer wrote, decided by login as for reviewers, an "Edit description" button sits at the trailing end of the Conversation / Files changed row while the conversation is shown. It swaps the web view for a native editor in the same place: a plain `NSTextView`, monospaced, with spelling, smart quotes, dashes, text replacement and link detection off, as it holds markdown that GitHub renders and any substitution would change what's sent. Below it a caption says the description is GitHub-flavoured markdown, beside Cancel and Save; ⌘↩ saves and Esc cancels, the text view taking both itself so they work while typing. Save is disabled until the text differs, and Cancel with changes asks before dropping them. There's no preview: saving shows GitHub's own rendering, as the conversation is fetched again straight after, and a second renderer of our own could disagree with it.

The editor starts from the description fetched afresh from GitHub when it opens, not the stored copy, because descriptions are also edited on github.com, where images are uploaded and links added, and saving a stale copy would silently undo that. If that fetch fails the editor says so and offers Retry, rather than falling back to the stored copy. The raw `body` is still fetched and stored with the conversation, so it's at hand, but is never what's edited. Line endings are made newlines when the editor opens, since a description typed in a browser can come back with `\r\n` and would otherwise count as changed before anything was typed. Saving calls `updatePullRequest` with the body alone; a refusal keeps the editor open with its draft and the reason. A change made on github.com while the editor is open is still overwritten by saving; checking for one first was left out until it bites.

### The viewer's own PR shows "Self-reviewed" once every file to review is marked viewed

The author wanted a way to mark their own PR as ready for others to review, and reviewing it themselves in Loupe is that moment. So on a PR the viewer wrote, once every file to review (not the "Vendored, lockfiles and generated" section) is marked Reviewed, a quiet green "Self-reviewed" badge shows beside the state badge, in the lists and in the PR header. A file changed by a later push (`DISMISSED`) counts as not viewed, as when moving on. Whether the PR is the viewer's is decided as for its reviewers, by the author's login against the viewer's.

It's knowledge only Loupe has, derived from GitHub's viewed state plus the local diff: which files are to review comes from the diff, so producing a PR's diff records its reviewable paths beside its head commit, replaced with each diff. The badge needs that head to be the PR's current head, so a push clears it until the new diff is produced and its files reviewed. The lists show it from the store with no network, so a PR never opened in Loupe shows nothing; the header follows the viewer's marks as they're made. It does nothing on GitHub: no draft to ready, no label, no review request. Whether it should is left for later.

### Who could review is fetched once a run per repo, and filtered as you type

Searching GitHub (`assignableUsers(query:)` and the org's teams) after each pause in typing made every search in the request-a-review popover wait on two round trips. Instead a repo's assignable people and its org's teams are fetched once a run, all pages of 100, kept in memory by `owner/name` and shared by every tab, and the popover filters them locally on login and name, ignoring case, as each key is typed. The repos I review have about 16 to 21 assignable people and the org 8 teams, so it's one page of each. Opening the reviewers on one's own PR starts the fetch, so the popover usually opens full; a fetch already on its way is shared, and one that fails isn't kept, so opening the popover again retries. A refusal to read teams still leaves them out quietly and the people are kept; any other failure fails the fetch rather than being taken as no teams. They're not stored, so someone joining a repo shows up on the next launch.

### Pulling past the footer is pull-to-refresh: finger travel arms it, letting go fires it

This supersedes "Pulling past the footer is real scrolling, fires mid-drag, and fills the button" for the gesture itself; the filled button and the hint stay. Neither earlier version was the pull-to-refresh pattern the user expected. Measuring the rubber band's stretch made it too hard, as AppKit damps the stretch to a fraction of the finger's travel; unresisted slack firing mid-drag made it far too sensitive, as any drag running past the end fired. Now the rubber band is back and the footer is the last thing in the document, with no slack below it, and progress is the finger travel of a live drag counted from when the view is already at its end, so the damping no longer matters and reaching the end costs nothing. About 80pt of travel, the usual pull-to-refresh distance, arms it: one haptic tap, the button full and green, and the hint saying what letting go will do. Pulling back under that disarms it. It fires only when the fingers lift while armed, once per gesture; lifting short, or a cancelled gesture, does nothing and the fill empties as the rubber band springs back. Momentum never counts, so a fling into the end can't fire it, and a mouse wheel has no pull at all, using the footer's button or ⌘↓ and `]`. With firing on release there's nothing left of the gesture to swallow and no slack to glide back from, so both are gone. A short file still stretches its text view to the view's height, so it can be pulled too. The hint sits in the gap the rubber band opens below the footer and shows only during a live drag, fading in with progress.

### Grammars CodeEditLanguages lacks are vendored as C targets

CodeEditLanguages has no Protocol Buffers grammar, and the repos I review have many `.proto` files, so that grammar is vendored as its own SwiftPM C target, `TreeSitterProto`: upstream's generated `parser.c` and headers, unmodified, with its `highlights.scm` as the target's resource. It's coder3101/tree-sitter-proto, which nvim-treesitter uses and which is maintained, at a tagged release; mitchellh's and treywood's grammars haven't changed since 2021 and 2023. Its query uses the standard capture names the highlighter already maps, and its parser's ABI is within what the resolved tree-sitter runtime accepts. A generated parser is plain C with no build step, so vendoring it avoids the separate upstream SwiftPM manifests that "Grammars come from CodeEditLanguages" moved away from. `Scripts/update-tree-sitter-proto.sh <ref>` re-fetches it, records the tag and commit in `VERSION`, and prints the parser's ABI to check. Scalar types (`string`, `int32`) take the keyword colour, as the query marks them built-in types; as with other grammars, a hunk starting inside a `message` can leave its first fields' types plain. Its query is found the way CodeEditLanguages' are, in its resource bundle beside the executable or in the app's `Contents/Resources`, where `Scripts/bundle.sh` already copies every bundle. Another missing language (HCL, Makefile) would be added the same way.

### Hidden context is expanded from the checkout, with GitHub's arrows

Hunk headers carry GitHub's expand arrows in their gutter: ↑ reveals 20 lines above a hunk, ↓ 20 below the hunk before, ↕ closes a gap of 20 lines or fewer in one go, and a row after the last hunk reveals 20 more towards the file's end. 20 is GitHub's step. A gap that closes merges its two hunks, keeping the earlier header's function context, and headers are recounted so they stay true to their lines. The arrows are characters in the gutter, not SF Symbols, as the gutter is text; they're tagged like the line numbers, so copies leave them out, and carry a tooltip and a pointing-hand cursor. They act on the first click even in an inactive window, as buttons do.

The lines come from the file at the head of the changes shown, the PR's head or the picked commit, read with `git show` once per file and commit and kept while the tab lives, rather than by diffing again with more context: lines outside hunks are the same on both sides, so the new side's text and the offset the changes before them leave give both line numbers, and the change is a pure function on the parsed diff that tests can check against `git diff -U` with the whole file. The file is read when shown so the end-of-file row can be offered; until it's read, only the arrows that don't need its length show. Added, deleted and binary files have nothing to reveal. What's revealed is kept per file and range, so moving between files or commits keeps it, and producing the diff again drops it, as the lines it was revealed around may have moved. The clicked arrow's row holds still on screen while the lines arrive, so another click reveals more; when the gap closes and the row goes, the code next to it holds instead. Revealed rows are ordinary context rows, so they're highlighted with the rest of their hunk.

## Not yet decided

- How review threads and comments render inline in the diff, and how outdated threads (no current line) are shown. The next spike.
- Review submission: pending review via `addPullRequestReview`, threads via `addPullRequestReviewThread`, then `submitPullRequestReview`.
