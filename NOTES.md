# Loupe spike: findings

A spike for a native macOS PR-review app. It checks the GitHub GraphQL data shapes we'd need (`probe/`) and prototypes the diff view, the riskiest part (`Sources/`).

## Build and run

Needs Swift 6 (Command Line Tools are enough; no Xcode). All commands run from the project root.

```sh
swift build                 # debug build
swift test                  # diff tests, plus PR list tests against a fake GitHub and SQLite (swift-testing)
swift build -c release      # for meaningful bench numbers
```

Open the start screen: your open PRs (drafts included) beside the open PRs awaiting your review, newest first. It authenticates with `gh auth token`, so `gh` must be signed in. Clicking a PR (or selecting it with the arrow keys and pressing Return) opens it in a tab:

```sh
swift run Loupe
```

The PRs are kept in SQLite at `~/Library/Application Support/Loupe/loupe.sqlite`, so launch shows the last-known lists straight away, then refreshes in the background: on launch, every few minutes, on ⌘R, and when the app comes to the front with lists more than a few minutes old. A list's first load pages through its search for open PRs in full and makes the stored list match it. Every refresh after that asks only for PRs in the list updated since its last refresh (`updated:>=`, two minutes earlier to allow for lag, any state), and adds or updates those without dropping anything; the refresh time recorded is when the request started. Merged and closed PRs therefore stay stored with their state, and the list shows only open ones unless the toolbar's "Show closed and merged" toggle is on (remembered between runs), when they appear muted with a badge. A PR you've reviewed never reappears in the to-review search to say so, so each refresh also checks every to-review PR directly (`nodes(ids:)`) and drops those that are no longer open or no longer request your review; a request to any team keeps a PR there, as team membership isn't checked. Your login for that check is looked up once and stored. If it fails, the stored lists stay up with a banner saying how old they are. To start afresh, quit the app and delete the database (and its `-wal`/`-shm` files):

```sh
rm ~/Library/Application\ Support/Loupe/loupe.sqlite*
```

After each refresh the app looks for each listed repo's local checkout, for diffing PRs locally later. A repo it has no checkout stored for is looked for as a directory with the repo's name (not `<repo>-<branch>` worktree copies) under `~/Development/tamarinworks/`, then `~/Development/GitHub/`, and accepted only if its `origin` is that repo on github.com. Finds are stored in the `localRepo` table; misses aren't, so they're looked for again next refresh. A stored checkout whose directory has gone is dropped and looked for afresh. Each row shows a folder icon when the checkout is known; right-click to reveal it in Finder, or to locate it by hand when it wasn't found. The search roots are `CheckoutResolver.defaultSearchRoots`, overridable through `PullRequestListModel`'s `checkoutSearchRoots`. Git is only ever run read-only against checkouts. The git run is Homebrew's when installed (`/opt/homebrew/bin/git`, then `/usr/local/bin/git`), else `/usr/bin/git`; `PATH` isn't consulted, and `LOUPE_GIT=<path>` overrides the choice. The path and its `git --version` are logged once, at first use: `log stream --predicate 'subsystem == "com.glenmailer.Loupe" && category == "git"'`. To fix a wrong mapping, quit the app and delete its row:

```sh
sqlite3 ~/Library/Application\ Support/Loupe/loupe.sqlite "DELETE FROM localRepo WHERE nameWithOwner = '<owner>/<repo>'"
```

The app has one window. Under its title bar a strip starts with a "Pull Requests" button, always there and not a tab, which shows the lists, then a tab per opened PR in the order opened. A tab is two rows: `repo #number` in bold over the PR's title, cut short with an ellipsis; it shows a close button while hovered or selected. Tabs share the strip's width equally between a minimum and a maximum, and past the minimum the strip clips rather than scrolls. The window is titled "Pull Requests" with the lists shown, or `repo #number` with the PR's title beside it, and its toolbar holds the lists' refresh controls or the PR's "Open on GitHub" and "Copy Link" (⇧⌘C), which puts the PR's github.com link on the pasteboard. Each PR's view is made when its tab is first shown and kept, hidden, while another is, so it keeps its diff, scroll positions and conversation. Opening a PR that already has a tab shows it. Keys: ⌘1 shows the lists; ⌘W closes the shown PR's tab (nothing on the lists) and ⌥⌘W all of them, closing the shown tab shows the one after it, or before it if it was last; ⌘⇧[ / ⌘⇧] and ⌃⇧Tab / ⌃Tab step through the strip with the lists first, wrapping; ⌘2–⌘8 pick the 1st–7th PR tab and ⌘9 the strip's last item. The window has no close button. Open PRs and the shown one are stored (`openTab` table, `selectedTab` setting) and reopened next launch; a PR with an open tab stays stored even after it leaves both lists.

A PR's tab shows the PR's header (state, CI, review decision, `head → base`, "Open on GitHub") over its changed files and diff, produced from the repo's local checkout, showing each step: finding the checkout, fetching, diffing. With no checkout known it says so and offers "Locate Checkout…". In the checkout it runs, all without touching branches, the index or the working tree:

```sh
git fetch --no-tags --no-write-fetch-head origin +refs/pull/<N>/head:refs/loupe/pull/<N>/head
git cat-file -e <baseRefOid>^{commit} || git fetch --no-tags --no-write-fetch-head origin <baseRefName>
git merge-base <baseRefOid> <head>
git log --reverse -z --format=%H%x1f%P%x1f%s <merge-base>..<head>   # the PR's commits, oldest first
git diff --name-status -z -M <merge-base> <head>                   # every changed path and what happened to it
git cat-file --batch-check   # <head>:<dir>/.gitattributes per line, for each changed path's directories
GIT_INDEX_FILE=<temp> git update-index -z --index-info   # those found, into an index of their own
GIT_INDEX_FILE=<temp> git check-attr --cached -z --stdin linguist-generated linguist-vendored linguist-documentation   # the paths on stdin
git cat-file --batch   # <head>:<path> per line (<base>:<path> if deleted), for paths only content can decide
git diff -M <merge-base> <head> -- . ':(exclude,top,literal)<hidden path or directory>' ...
git diff -M <merge-base> <head> -- ':(top,literal)<hidden path>'   # a hidden file, once it's shown
```

A single commit's changes are diffed the same way, from its first parent (or the empty tree, for a root commit) to the commit.

Hunk headers have GitHub's expand arrows in their gutter: ↑ reveals 20 more lines above a hunk, ↓ 20 more below the one before, ↕ the whole gap when it's 20 lines or fewer, and a row after the last hunk has ↓ for the file's end. The lines come from the file at the head of the changes shown (the PR's head, or the picked commit), read once with `git show --no-textconv <oid>:<path>` when the file is shown and kept while the tab lives. Added, deleted and binary files have no arrows. What's revealed is kept per file and range, so it survives switching files and commits, and Reload drops it.

Fetches time out after two minutes and other git commands after one; a failure shows git's stderr with a "Try Again" button. Which paths are hidden is `PathFilter`'s decision: a path under the repository's root `vendor/` (or matching Linguist's `documentation.yml`, off by default), a lockfile (`go.sum`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`), a file whose first lines Linguist's `generated.rb` takes for generated (`GeneratedCode`, such as Go's `// Code generated … DO NOT EDIT.` header on a `.pb.go`; read from git at the head, or the base for a deleted file, only for names a rule applies to), or a path the `.gitattributes` files at the head of the changes shown (not the checkout's working tree) mark `linguist-generated` or `linguist-vendored`; either attribute set to false keeps a path that would otherwise be hidden. The hidden paths are excluded from the diff by literal pathspec, collapsed to the highest directory with nothing kept in it, so a vendored tree is one argument. The sidebar still lists them, below the files to review under "Vendored, lockfiles and generated", each with what happened to it (from `--name-status`); one is diffed on its own only when it's selected, and kept in memory, its row then showing its line counts. They can be marked reviewed like any file, but the "N of M reviewed" count, ⌘↓ and `]`, and "All files reviewed" go by the files to review alone. The diff is kept in memory per PR, so switching tabs doesn't redo it. When each PR's diff was last produced, from which head and merge-base, is stored in `pullRequestDiff` (the diff text isn't). To see where Loupe has fetched to in a checkout:

Review threads show in the whole PR's diff ("All N commits"), not in a commit's. Each thread sits under the line it ends on (`line` on `diffSide`: the head for RIGHT, the base for LEFT, so a comment on a deleted line sits under it), with its line range in its header; threads on one line share a block. Outdated threads, those on the whole file, and those on a line the diff doesn't show come after the last row under "Not on the current diff", each with the end of the diff it was made on; revealing a hidden line brings its thread into place. Resolved threads are one line ("Resolved · N comments · login") until clicked, and hidden comments a line saying so. Bodies are GitHub's `bodyHTML` read by `CommentBlock` (in `LoupeCore`) into paragraphs, code, quotes, list items and rules, shown as SwiftUI `Text`; images become links. Each block is an `NSHostingView` laid over an empty row of the text view (`DiffBlock` in `DiffRenderer`), whose height follows the view's own; that row is tagged as gutter, so copies leave it out. The file list shows each file's unresolved threads beside its name, hidden files' included. Threads come with the conversation, on opening and Reload.

A thread's "Reply…" opens a plain-text field (⌘↩ sends, Esc cancels, asking first if anything is typed); the reply posts at once with `POST /repos/{owner}/{repo}/pulls/{number}/comments/{comment_id}/replies`, naming the thread's first comment by `databaseId`. "Resolve conversation" and "Unresolve conversation" in a thread's header call `resolveReviewThread` and `unresolveReviewThread`, showing the change at once and putting it back if GitHub refuses. After either, the threads alone are fetched again (`GitHubClient.reviewThreads(ofPullRequest:)`) and stored. Refusals show under the thread. None of these was run against the real API; the tests drive them through the fake.

Hovering a row of the PR's own diff (not a hunk header or a revealed line, and only on "All N commits") shows a "+" in its gutter; clicking it opens a field under the row that posts a new single-line thread at once with `POST /repos/{owner}/{repo}/pulls/{number}/comments` (`commit_id` is the diff's head, `path`, `line`, `side`), then fetches the threads again. One new comment is open at a time.

```sh
git -C <checkout> for-each-ref refs/loupe/
```

A PR is one pane: a sidebar with a "Conversation" row at the top, then the commit picker and file list, beside either the conversation or the selected file's diff. Clicking the Conversation row (or ⌃1, in the View menu) shows the conversation and leaves no file selected in the list; clicking a file (or ⌃2) shows the files again, and the file selected before comes back. A PR opens on its conversation and each tab remembers its choice while open. Above the file list a popup picks "All N commits" (the PR from its merge-base, the default) or one of the PR's commits, oldest first, listed by `git log` from the checkout. A commit's changes are diffed the first time it's picked and kept in memory, so switching back is instant; the shown file stays if the commit changed it. Reload goes back to "All N commits". "All N commits" in the picker's list counts the whole PR's files to review. The conversation is fetched by GraphQL when the PR's tab opens and on Reload (`GitHubClient.conversation(ofPullRequest:)`: the description's `bodyHTML`, the timeline paged by 100, review threads with their comments, and the head commit's CI contexts) and stored in the `conversation`, `timelineItem`, `reviewComment`, `reviewThread`, `threadComment` and `checkContext` tables, so a later opening shows it at once. It's shown in one `WKWebView` per tab, made the first time the conversation is shown and kept while the files are shown, so its scroll position survives switching. The page is assembled by `ConversationHTML` (in `LoupeCore`) from the template `Sources/Loupe/Resources/conversation.html` and its stylesheet `conversation.css`: GitHub's `bodyHTML` goes in verbatim, everything else is escaped, a Content-Security-Policy allows no scripts and only GitHub's images, and links open in the default browser.

On the viewer's own PRs (their login against the PR's author), the Conversation tab has an "Edit description" button at the right of the Conversation / Files changed row. It fetches the description's markdown afresh (`node(id:) { ... on PullRequest { body } }`, `GitHubClient.pullRequestBody(id:)`), never the stored `body`, and shows it in a monospaced plain-text editor in place of the web view, with Cancel (Esc, asking first if anything changed) and Save (⌘↩, disabled until the text changes). If the fetch fails it says so with Retry. Save sends `updatePullRequest(input: { pullRequestId, body })` (`updatePullRequestBody`), then fetches the conversation again so the page shows GitHub's rendering, and closes the editor; a refusal keeps the draft with the error under it. The editor's state is `DescriptionEditor`, held by the tab.

While a PR's tab is open the app watches it for changes on GitHub, as github.com does, and never replaces the diff being read. It polls `GET /notifications?participating=true` with the `If-Modified-Since` of the last poll, waiting between polls as long as `X-Poll-Interval` says (60 seconds when it doesn't); a 304 means nothing changed and costs no rate limit, and nothing is marked as read. When a poll returns notifications, the open PRs they name (by `subject.url`) are looked up in one `nodes(ids:)` query and their stored rows updated. If notifications are refused (403 or 404, as for a token that can't read them) every open PR is looked up that way each minute instead, for the rest of the run; any other failure does the same for that round and polls again next time. When an open PR's stored row has changed since its diff was produced, by this or by the lists' refresh, a banner at the top of its tab says "New commits pushed" (its head moved) or "Updated on GitHub" (its update time, state, review decision, or commit, comment or review thread count changed), with Reload, which looks the PR up again and produces the diff anew, keeping the shown file, and a dismiss button, which keeps the diff until the PR next changes. The lists show the updated rows as usual. A snapshot run doesn't poll.

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

### Opening PR links from other apps

The bundle declares the `loupe` URL scheme, and `https` as an alternate handler only, so Loupe can be picked for a link without becoming the default browser (see "Links from other apps open in Loupe" in `DESIGN.md`). Launch Services learns the URL types when the bundle is registered, which opening it does, so `./start.sh` after a rebuild is enough. To force it without opening the app:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f .build/Loupe.app
```

To try it, with the bundle built and registered (each launches Loupe if it isn't running):

```sh
open 'loupe://github.com/tamarinworks/porter/pull/1522'
open 'loupe:///tamarinworks/porter/pull/1522'
open -a Loupe https://github.com/tamarinworks/porter/pull/1522
```

A router such as Finicky can send Slack's and mail's PR links here, either by rewriting `https://github.com/*/pull/*` to the same URL with the scheme `loupe`, or by opening those URLs with the app `com.glenmailer.Loupe`. The PR opens in its tab, looked up on GitHub if it isn't stored; a PR GitHub won't show goes to the browser, as does any other https link Loupe is given. A `loupe:` URL that names no PR is logged and dropped. Links Loupe sends to the browser carry `via=loupe` when they're on github.com, so the router's PR rule should skip URLs with that parameter, or it sends Loupe's own "Open on GitHub" straight back.

## Snapshots

The app can draw its window to PNGs, title bar, toolbar and tab strip included, without screen-recording permission. The Debug menu has "Save Snapshot of Window…" (⌥⌘S) and "Snapshot All Tabs to Desktop".

With `LOUPE_SNAPSHOT_DIR` set, the app waits until the lists have refreshed and each open PR's diff is ready or has failed (at most 20 seconds), writes `<index>-<title>.png` into that directory with each item of the tab strip shown in turn, the lists first, prints their paths and quits. `LOUPE_DATABASE` points it at another database. `LOUPE_SNAPSHOT_COMMIT=<n or oid prefix>` shows each PR's nth commit (counting from 1, for a number under four digits) or the commit whose oid starts with it, rather than all its changes. `LOUPE_SNAPSHOT_FILE=<substring>` then shows each PR's first file whose path contains it, rather than its first file, looking at hidden files after the rest and waiting for a hidden one's diff, and for a hidden npm lockfile's package changes. `LOUPE_SNAPSHOT_TAB=conversation` shows each PR's conversation and `files` its files; unset, each PR shows whichever it opens on. `LOUPE_SNAPSHOT_EDIT_DESCRIPTION=1` then opens the description's editor on each of the viewer's own PRs, fetching the description from GitHub (read-only) as the button would; nothing is saved. A conversation shown either way is waited for until fetched and its web view has finished loading; web views are drawn into the PNG from their own snapshots, as WebKit draws in another process. `LOUPE_SNAPSHOT_COMMIT` or `LOUPE_SNAPSHOT_FILE` shows the files whatever `LOUPE_SNAPSHOT_TAB` says, so the file is visible. `LOUPE_SNAPSHOT_CLICK_TAB=<n or lists>` first clicks the strip's nth PR tab (counting from 1) or the lists button, by sending a synthesised mouse down and up at its centre through the window as a real click would arrive, and writes `clicked-<title>.png` of what the click showed, before the usual PNGs; pick an item other than the one stored as shown to see the click switch it. `LOUPE_SNAPSHOT_CLICK_CONVERSATION=1` shows each PR's files, then clicks the sidebar's Conversation row with a synthesised mouse down and up sent through the window, printing the section before and after, and writes `conversation-<title>.png` of what the click showed, before the usual PNGs. `LOUPE_SNAPSHOT_CLICK_FOLDER=1` shows each PR's files, clicks the last directory row drawn in the tree with a synthesised mouse down and up sent through the window, then presses ↓ four times in the list, printing the selected file, the list's row count and its selected row before and after each, and writes `folder-<title>.png`, before the usual PNGs; a click on a directory should fold it and leave the selection alone, and ↓ should pass over directories. `LOUPE_SNAPSHOT_CLICK_FOOTER=1` scrolls each shown diff to its end and clicks its footer's button with synthesised mouse events sent through the window, printing what the click hit and the selected file before and after, so a real click is proven to mark the file reviewed and move on. Pick an already reviewed file with `LOUPE_SNAPSHOT_FILE` and the click moves on without writing a viewed state to GitHub. `LOUPE_SNAPSHOT_OPEN_COMMITS=1` shows each PR's files and, once its commits are counted, opens its commit picker's list and writes `commits-<title>.png`, before the usual PNGs; pair it with `LOUPE_SNAPSHOT_COMMIT` to see a commit ticked. AppKit moves the popover onto a screen, away from the off-screen window, so the run moves it back under the picker, and draws its content on a plain panel, as the popover's material doesn't draw off screen. `LOUPE_SNAPSHOT_SHOW_STALE=1` shows the lists and clicks the To review caption that counts requests hidden for their age, with a synthesised mouse down and up sent through the window, and writes `stale-shown.png` of the hidden requests listed, before the usual PNGs, which then show them too. `LOUPE_SNAPSHOT_SHOW_CHECKS=1` opens the checks popover on the lists' first checks glyph (the top row, leftmost column first) and on each PR's header glyph, and writes `checks-<title>.png` before the usual PNGs; the popover is moved back and drawn as the commit picker's is. `LOUPE_SNAPSHOT_EXPAND=<n>` scrolls each shown diff so its nth hunk header (counting from 1) is near the top and clicks the arrow there that reveals lines above it (↑, or ↕ for a small gap) with a synthesised mouse down sent through the window, printing what it hit and the file's hunk headers afterwards; `LOUPE_SNAPSHOT_EXPAND=all` reveals every unchanged line of each shown file instead. A diff waits for its PR's conversation, which brings its review threads. `LOUPE_SNAPSHOT_OPEN_RESOLVED=1` opens every resolved thread, and `LOUPE_SNAPSHOT_REPLY=1` opens a reply on the first unresolved thread of each shown file, in GitHub's order, without typing or sending anything. `LOUPE_SNAPSHOT_COMMENT=<line>` scrolls each shown diff to the row of that new-side line, moves the mouse over it through the text view's `mouseMoved`, clicks the "+" that shows, and hovers it again, printing whether the "+" showed; nothing is typed or sent. `LOUPE_SNAPSHOT_DOUBLE_CLICK=<line>` scrolls each shown diff to the row of that new-side line and double-clicks its code with synthesised mouse downs and ups sent through the window, printing whether a comment opened there and how much text is selected; nothing is typed or sent. `LOUPE_SNAPSHOT_THREAD=<n>` scrolls each shown diff to its nth block of threads (counting from 1, down the diff), printing where each block is. `LOUPE_SNAPSHOT_PULL_EVENTS=<points>` scrolls each PR's shown diff to its end and pulls that far past it with synthesised trackpad scroll events (continuous, with began, changed and ended phases, a few milliseconds and 4pt apart, stamped with the time) sent through the scroll view's `scrollWheel(with:)`, as a drag begun at the end; it writes `pull-<title>.png` halfway, with the strip below the footer revealed and the fill part way, and `armed-<title>.png` at the end, before the usual PNGs, and prints the pull's travel, reveal, progress and arming and the clip view's bounds and inset at rest, halfway, at the end, on letting go and once settled. 200 arms it. `LOUPE_SNAPSHOT_PULL_BACK=<points>` scrolls back that far before letting go, so a pull scrolled back past the end can be seen not to fire. A pull that fires prints `pull fired: markViewedAndAdvance` instead of marking the file, so nothing is written to GitHub. AppKit doesn't scroll the document for these events in the off-screen run, so travel left over once the pull is back at the end moves nothing there, though it does with a real trackpad. `LOUPE_SNAPSHOT_RENDERED=1` switches each PR's shown file, if it's markdown, to Rendered and waits until GitHub has rendered it (or failed) and its web view has loaded, so with `open` doesn't pass the environment on, so run the bundle's executable directly: `LOUPE_SNAPSHOT_REVIEW=1` opens "Finish your review" from the header's Review button on each PR the viewer can review (open, and not their own), filling its summary from any pending review as the button does, and writes `review-<title>.png` before the usual PNGs; the popover is moved back and drawn as the commit picker's is, and nothing is submitted. Point the copy's `openTab` and `selectedTab` setting at someone else's PR to see it. `LOUPE_SNAPSHOT_REVIEW=1` opens the review summary's popover from the header's "Summary…" button on each PR the viewer can review (open, and not their own), filling it from any pending review as the button does, and writes `review-<title>.png` before the usual PNGs; the popover is moved back and drawn as the commit picker's is, and nothing is submitted. `LOUPE_SNAPSHOT_REVIEWERS=1` fetches the reviewer candidates and GitHub's suggested reviewers (read-only) on each of the viewer's own PRs, prints those offered with the suggested marked, opens the Reviewers picker and writes `reviewers-<title>.png` before the usual PNGs; the popover is moved back and drawn as the commit picker's is, and nobody is asked to review. `LOUPE_SNAPSHOT_PENDING_LIST=1` prints the pending comments of each PR with a pending review, opens their list from the header's "N pending comments" and writes `pending-<title>.png` before the usual PNGs; the popover is moved back and drawn as the commit picker's is, and nothing is deleted. `LOUPE_SNAPSHOT_EDITOR=1` prints, for each PR, what its "Open in" button would do (the editor, branch and checkout, and whether the checkout is clean enough to switch) from read-only git, without fetching, switching or opening anything. `LOUPE_SNAPSHOT_REACTIONS=1` scrolls each conversation to its first reaction pill, or its first comment's reactions if no one has reacted, opens the reaction picker beside it and writes `reactions-<title>.png` before the usual PNGs; nothing is clicked or sent. `LOUPE_SNAPSHOT_SHOW_THREAD=1` scrolls each conversation with threads to its first "Show in diff" (`=reply`: its first "Reply…" in a thread that isn't folded), writes `thread-conversation-<title>.png`, clicks the link in the page so it goes through the web view's navigation delegate, prints where that left the tab (a reply leaves the section `.conversation`) and whether the reply opened in a popover by the thread or in the fallback sheet, and writes `thread-<title>.png`, with a reply's popover moved back by its thread and drawn as the commit picker's is; nothing is typed or sent. `LOUPE_SNAPSHOT_HOLD_CHECK=1` looks each PR up on GitHub by id after the other hooks, as showing its tab does, and holds that and every later GitHub request unanswered, printing whether each PR is being checked, so the PNGs show the spinner after the header's "updated …".

`LOUPE_SNAPSHOT_HOLD_PHASE=<resolving|fetching|diffing>` holds each PR's first load at that step for good, so the PNGs show the sidebar's placeholder and the detail pane's wait; pair it with `LOUPE_SNAPSHOT_TAB=files` to see the detail pane.

`LOUPE_SNAPSHOT_HOLD_RELOAD=1` reloads each PR whose diff is ready, after the other hooks, and holds the reload as it diffs, printing where each is held, so the PNGs show the old diff and file list dimmed with the commit picker's spinner.

`LOUPE_SNAPSHOT_HOLD_COMMIT=<n or oid prefix>` picks that commit on each PR, as `LOUPE_SNAPSHOT_COMMIT` does, but holds its diff, so the PNGs show the picker naming the commit beside its spinner and the changes shown before dimmed. A first load still going when the run stops waiting (20 seconds) is held at its diff too.

```sh
Scripts/snapshot.sh /tmp/loupe-snaps   # builds the bundle, runs it as below

# the same by hand, against a copy of the database
sh Scripts/bundle.sh
sqlite3 ~/Library/Application\ Support/Loupe/loupe.sqlite ".backup /tmp/loupe-db/loupe.sqlite"   # copying the WAL files by hand can give an unreadable copy
LOUPE_DATABASE=/tmp/loupe-db/loupe.sqlite LOUPE_SNAPSHOT_DIR=/tmp/loupe-snaps .build/Loupe.app/Contents/MacOS/Loupe
```

The run is an accessory process that's never activated, and its window is transparent and off every screen, so nothing shows while it runs.

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

- `DiffParser` (pure Swift) turns `git diff` output into files → hunks → lines. Each line is `.context(old:new:)`, `.addition(new:)` or `.deletion(old:)`, so line numbers are never optional where they exist. It handles renames, copies (the user's git config has `diff.renames=copies`), deletions, pure renames with no hunks, "\ No newline", and CRLF (it splits on LF bytes, because Swift treats `"\r\n"` as one `Character`). `PathFilter` hides a root `vendor/` and lockfiles, and the sidebar shows how many it hid.
- `RenderedDiff` turns one file into a single `NSAttributedString`. The gutter (old/new numbers and the `+`/`-` marker) is inline text, tagged with an attribute so copying a selection yields plain code. Each row is tagged with its kind, and an array of row start offsets maps a click to a row (binary search) and from the row to its `DiffAnchor`.
- `DiffTextView` is an `NSTextView` subclass: non-editable, selectable, with a find bar. It uses TextKit 1 with **non-contiguous layout**. A small `NSLayoutManager` subclass paints full-width row backgrounds, once per visual line, so wrapped rows are tinted throughout. A single click (not a drag-select) reports the anchor.
- Long rows soft-wrap at the view's width by default. Every row's paragraph style has a `headIndent` of the gutter's measured width, so continuation lines start under the code. View ▸ Wrap Lines (⌥⌘L) turns it off; the setting is `wrapLines` in `UserDefaults` and open diffs follow it live. Clicks map by character offset, so continuation lines resolve to their row's anchor.
- Code is syntax-highlighted with tree-sitter (`SyntaxHighlighter.swift`), chosen by the path's Linguist language; other files stay plain. For each hunk it parses the new side (context and additions) and the old side (context and deletions), runs the grammar's `highlights.scm`, and maps the captures back onto the rows: context and added rows take the new side's colours, deleted rows the old side's. Partial snippets parse with error recovery, so a hunk starting mid-expression can colour a token or two oddly, as GitHub's can. Colours are Primer's syntax palette (`DiffColors.syntax*`), light and dark. Plain identifiers and punctuation stay the text colour, as on GitHub. The colours are applied as the layout manager's temporary attributes rather than to the text storage: on the 46k-row file, adding 70k colour runs to the storage took about 720ms however it was done (each splits an existing attribute run), against 135ms as temporary attributes, which also leave layout and copying alone. Files up to 5,000 rows are highlighted before first paint; larger ones paint plain, are parsed off the main thread, then coloured top first in slices of 5,000 runs.
- Grammars come from CodeEditLanguages 0.1.20, one package bundling about 40 prebuilt grammars (as an xcframework) with their queries. A path's language is looked up in Linguist's `languages.yml` (`Linguist.swift`): exact file name first, then the longest known extension (`schema.yml.mysql` is YAML, not SQL), then the name less its last extension (`Dockerfile.prod`). Linguist's interpreter, modeline and content heuristics aren't run, so an ambiguous extension takes the first of its languages (by name) that has a grammar: `.sql` is SQL rather than PLSQL, `.h` is C. The Linguist language then picks the grammar of the same name, or one from a small table where names differ or languages share a grammar (Shell is bash, JSON with Comments is JSON, Gradle Kotlin DSL is Kotlin). Queries are composed as each grammar's tree-sitter.json does (TypeScript on JavaScript's, JSX with JavaScript and TSX) rather than by CodeEditLanguages' `TreeSitterModel`, which is a non-thread-safe singleton and leaves the JSX patterns out of TSX. (Its `queryURL` would be no use anyway: it assumes Xcode's bundle layout and doubles the `Resources` folder under SwiftPM.) Where several patterns capture one node, the last wins, as in tree-sitter's own highlighter; Go's query is still ordered for the old first-wins rule, so Go uses that.
- Languages found in the repos I review now highlighted: Go (and `go.mod`), TypeScript, TSX, JavaScript, Ruby, YAML, JSON, SQL, Bash, Dockerfile, Markdown (block structure only; inline code and emphasis need the inline grammar's injection, which isn't run), HTML, CSS and Swift, along with Python, TOML, Rust, Java, Kotlin, PHP and others the package carries. Protocol Buffers (`.proto`) comes from coder3101/tree-sitter-proto, vendored as the `TreeSitterProto` target since the package has no grammar for it; `Scripts/update-tree-sitter-proto.sh <tag>` refreshes it, and `Sources/TreeSitterProto/VERSION` says which it is. Still plain, for want of a grammar in the package: Makefile and HCL/Terraform.
- Linguist's data is vendored from a tagged release under `Sources/LoupeCore/Resources/linguist/`, converted to JSON, with its MIT licence and the tag in `VERSION`. To refresh it, with the sandbox off: `Scripts/update-linguist.sh v9.7.0` (any tag). Its regexes are written for Ruby; any ICU can't compile is skipped and logged under the `linguist` category (none at v9.7.0).
- CodeEditLanguages' `CodeLanguage` isn't used at all: making one reaches its SwiftPM `Bundle.module` accessor, which looks only beside `Loupe.app`'s root and in the build directory, and stops the process if both miss. The highlighter calls the grammar functions in its prebuilt framework directly and finds the queries itself, beside the executable or in the app's `Contents/Resources` (where `Scripts/bundle.sh` copies every resource bundle), as it does Linguist's data. A grammar or query it can't find is logged once and that language stays plain. Checked by running the bundled app's `--bench` with the build directory's copy moved aside (it highlights), then with both moved aside (plain, no crash).
- `DiffView` is the `NSViewRepresentable` wrapper; the `App` is a `NavigationSplitView` with the file list on the left.

### Measured performance

Release build on an Apple M4, measured with `--bench`:

| | 92 rows | 5,355 rows | 45,919 rows |
|---|---|---|---|
| build attributed string (with word-level changes) | 0.5ms | 17ms | 150ms |
| set text storage | 4.7ms | 6.9ms | 18ms |
| lay out first screen | 1.3ms | 1.6ms | 2.0ms |
| draw a screen (first / middle) | 3.0 / 1.9ms | 3.2 / 7.7ms | 3.2 / 43ms |
| lay out whole file (only on jump-to-end) | ~0 | 66ms | 792ms |

With wrapping on (bench viewport 1200pt wide; `--bench` now times the view both ways, wrapped second):

| | 92 rows | 5,355 rows | 45,919 rows |
|---|---|---|---|
| set text storage | 0.2ms | 2.6ms | 13ms |
| lay out first screen | 1.2ms | 1.5ms | 1.7ms |
| draw a screen (first / middle) | 1.9 / 1.9ms | 2.0 / 7.3ms | 2.5 / 35ms |
| lay out whole file | ~0 | 66ms | 806ms |

Syntax highlighting, timed separately by `--bench` (the TypeScript files are from marmot, diffed against `/dev/null`):

| | rows | parse and query (off main above 5k rows) | apply to the view (main) | runs |
|---|---|---|---|---|
| Go `snapshotter.go` | 92 | 2.8ms | 0.1ms | 124 |
| Go `types.go` | 5,355 | 11ms | 11ms | 5,610 |
| Go `api.go` | 45,919 | 172ms | 135ms, in slices | 69,751 |
| TSX test file | 4,373 | 46ms | 10ms | 5,766 |
| TS `generated/graphql.ts` | 14,928 | 480ms | 137ms, in slices | 130,342 |

These are with CodeEditLanguages' grammars. On the same run, the upstream packages (commit `4ba5dfa`) took 2.8ms, 10.2ms and 161ms for the Go files, 49ms for the TSX file and 442ms for `graphql.ts`, so the prebuilt Go and TypeScript grammars are 6–9% slower and TSX slightly faster, the large files' extra time all off the main thread. Run counts differ slightly as the bundled queries differ. The TypeScript fixture is captured read-only from the marmot checkout, diffed against the empty tree: `git -C <checkout> diff 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD -- src/generated/graphql.ts <a .test.tsx file> > fixtures-local/marmot-ts.diff`, then `--bench fixtures-local/marmot-ts.diff graphql.ts`.

So a Go file under 5k rows opens about 20ms slower, and the TSX file, still under the threshold, about 60ms slower; TypeScript parses several times slower per row than Go. Above the threshold the first paint is unchanged and the colours follow once the background parse finishes. Drawing a screen with colours costs the same as without.

Wrapping costs nothing measurable on open: TextKit lays out only the visible lines either way. The unwrapped figures were unchanged on the same run (13.8ms to set the 46k-row file's storage, 1.5ms first screen); the wrapped run's lower storage time is mostly warm caches from going second.

Parsing the whole 260k-line, 741-file diff took 53ms.

These are with GitHub's spacing (20pt rows), a tinted gutter and word-level highlighting of modified lines. Against the previous layout on the same run, the 46k-row file builds in 150ms rather than 127ms and sets its storage in 18ms rather than 14ms: the gutter is wider and changed rows carry more attribute runs, and the word diffs run in the same pass; how the extra time splits between these wasn't measured. Whole-file layout is slower, with the file a third taller.

So a 5k-line file opens in about 35ms, comfortably fast. A 46k-line file takes about 170ms to open, then is smooth, apart from a one-off ~0.8s if you jump straight to the end.

## What was hard

- **Painting full-width row backgrounds without losing lazy layout.** The obvious place, `NSTextView.drawBackground(in:)` plus `glyphRange(forBoundingRect:)`, silently forced layout of the whole file on first paint: 61ms at 5k rows and 500ms at 46k, against 9ms once fixed. Moving the painting into `NSLayoutManager.drawBackground(forGlyphRange:at:)`, which only sees glyphs already laid out, fixed it. A test samples pixels to check the backgrounds are painted, and fails if they aren't.
- **Swift 6 concurrency with AppKit.** `NSLayoutManager` isn't `@MainActor`, so its overrides can't touch the view's state. Filling to the graphics context's clip bounds avoided needing the view at all.
- Merged-PR merge-bases and `FETCH_HEAD` races, covered above.

## What I'd change in the plan

1. **Get the diff and file list from git, not the API.** `files` pages at 100 and is dominated by vendored code, and the API's patch text isn't in GraphQL anyway. Fetch `refs/pull/N/head`, then diff `headRefOid` against the merge-base with `baseRefOid`, in a bare cache clone the app owns rather than the user's working checkouts. Use GraphQL for metadata, threads, CI and the inbox.
2. **Inline comment rendering is now the riskiest part**, and the next spike. A single `NSTextView` has no natural way to put a block between two rows. Options: a text attachment with a view provider, TextKit 2 custom layout fragments, or a stack of per-hunk text views with comment views between them. The last is simplest, but makes selection across hunks harder.
3. **Outdated threads need their own path.** Either fetch `originalCommit` and show that diff, or list them separately.
4. **Build the attributed string off the main thread** (or collapse files over ~10k rows by default), so a huge file doesn't stall the UI for 130ms.
5. Small things for later: the find bar also matches gutter digits; a "\ No newline" marker isn't drawn yet; quoted paths (filenames with unusual characters) aren't unquoted.

## Layout

- `Sources/LoupeCore/`: `DiffModel.swift`, `DiffParser.swift`, `DiffRenderer.swift` (attributed string and anchors), `DiffTextView.swift`, `SyntaxHighlighter.swift` (tree-sitter grammars, queries and mapping captures onto rows), `DiffColors.swift`, `PackageLockChanges.swift` (an npm lockfile's package changes, ported from `diff-package-lock`)
- `Sources/LoupeModel/`: `PullRequest.swift` (the PR summary and list types shared by the targets below), `Conversation.swift` (a PR's description, timeline, threads and checks)
- `Sources/LoupeGitHub/`: `GitHubClient.swift` (GraphQL over `URLSession`, pluggable transport; pages each search), `GitHubNotifications.swift` (the REST notifications poll, over the same transport), `GitHubCLI.swift` (`gh auth token`), `PullRequest.swift` (response decoding), `Conversation.swift` (the conversation query and its decoding), `PullRequestBody.swift` (a PR's description alone, and replacing it)
- `Sources/LoupeStore/`: `PullRequestStore.swift` (GRDB: one row per PR keyed by node id, list membership and per-list refresh times, set up by migrations), `LocalRepoStore.swift` (each repo's local checkout), `TabStore.swift` (open tabs and when each PR's diff was produced), `ConversationStore.swift` (each PR's conversation)
- `Sources/LoupeGit/`: `CheckoutResolver.swift` (finds, verifies and stores checkouts), `GitHubRemote.swift` (matches an origin URL to `owner/name`), `Git.swift` (picks which git to run, and runs it with a timeout), `PullRequestDiffer.swift` (fetches a PR into `refs/loupe/` and diffs it from its merge-base)
- `Sources/LoupeInbox/`: `PullRequestListModel.swift` (start-screen state wiring GitHub to the store; `onOpen` is where choosing a PR goes), `TabsModel.swift` (the open PRs, which is frontmost, and watching them for changes), `PullRequestTab.swift` (one open PR's diff, from checkout to ready, and whether the PR has changed since), `DescriptionEditor.swift` (editing the description of one of the viewer's own PRs), `ReviewThreads.swift` (where a file's review threads go in its diff)
- `Sources/Loupe/`: `Entry.swift` (PR list, diff file or `--bench`), `App.swift` (the menu bar and app delegate), `WindowManager.swift` (the AppKit-owned window, its title and toolbar, restoring the tabs, and the tab keys), `TabStrip.swift` (the tab strip under the title bar and the content it switches between), `Snapshots.swift` (window PNGs and the Debug menu), `PullRequestView.swift` (a PR's tab), `ConversationView.swift` (its Conversation tab's web view), `DescriptionEditorView.swift` (the description's editor, shown in its place), `ReviewThreadViews.swift` (review threads laid between a diff's rows), `ReviewView.swift` (the header's Review button and "Finish your review"), `Resources/conversation.html` and `conversation.css` (the conversation page's template), `RenderedMarkdownView.swift` (a markdown file rendered by GitHub, toggled from its diff's header), `PackageLockView.swift` (a hidden npm lockfile's package changes, toggled the same way), `GitHubWebPage.swift` (what both web views share: template, link handling), `Browser.swift` (every link sent to the default browser, marked when it's GitHub's), `Editors.swift` (opening a checkout in GoLand or VS Code), `PullRequestListView.swift`, `DiffView.swift`, `DiffCommands.swift` (the View and Review menus, and the review keys for the shown PR), `Bench.swift`
- `Tests/LoupeTests/`: tests, with fixtures from atrium#2912 (the 4-file diff, and edge cases cut from the full diff)
- `Tests/LoupeInboxTests/`: PR list tests against an in-memory GitHub that matches searches (author, review request, `is:open`, `updated:>=`) and review-request, PR and status lookups against the PRs in `probe/pr-list.json` (with their checks and mergeability from `probe/pr-status.json`), checking the shape of each search it receives, plus `probe/graphql-error.json`, and serves notifications in `probe/notifications.json`'s shape for each changed PR, with 304s, `X-Poll-Interval` and refusals; checkout tests against real `git init` repos in temp search roots; diff and tab tests against `FakeRepository`, a temp bare origin exposing `refs/pull/<N>/head` with a contributor clone and a reviewer checkout
- `probe/`: GraphQL queries, raw responses and `NOTES.md`; `incremental-query.graphql` → `incremental.json` confirmed the `updated:>=` search, PR `state`/`mergedAt`/`closedAt`, `viewer { login }` and the `reviewRequests` shape
