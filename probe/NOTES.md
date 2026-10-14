# GitHub GraphQL probe

Raw responses, captured 2026-10-14 with `gh api graphql`:

- `pr-query.graphql` → `pr-marmot-14569.json` (6 files, 2 reviews, 1 review thread) and `pr-atrium-2912.json` (741 files, mostly `vendor/`). Run with `gh api graphql -F owner=tamarinworks -F name=marmot -F number=14569 -F query=@probe/pr-query.graphql`.
- `inbox-query.graphql` → `inbox.json` (`is:pr is:open review-requested:@me`); `inbox-variants.json` compares counts with `user-review-requested:@me` and `draft:false`.
- `threads-marmot-last60.json`: review threads across marmot's last 60 PRs, to find outdated and multi-line comments.
- `mergeable.json`: `mergeable` on an open vs a merged PR.
- `pr-list-query.graphql` → `pr-list.json`: the start screen's two searches (`author:@me` and `review-requested:@me`) in one request, with CI rollup and branch names. Each node's `id` was looked up afterwards (by repo and number) and added, as the app keys stored PRs on it. The tests' fake GitHub serves these nodes as the full search results, paging them itself. `graphql-error.json` is a real GraphQL error response (a bad field). Both are test fixtures.
- `gh api '/notifications?participating=true' -i` → `notifications-headers.txt` (the 200's headers, then a 304's from repeating it with `If-Modified-Since`) and `notifications.json` (the first three of the page's 50 notifications, each `repository` cut down to a few fields). The tests' fake GitHub serves notifications in this shape.
- `viewed-files-query.graphql` → `viewed-files.json`: a PR's files' `viewerViewedState`, paged by `node(id:)`. `viewed-mutations.graphql` → `viewed-mark.json`: `markFileAsViewed(input: {pullRequestId, path})`; `unmarkFileAsViewed` takes the same input. Captured on stagehand#1727 by marking then unmarking one file, so nothing was left changed. `viewed-mark-error.json` is GitHub's `UNPROCESSABLE` refusal of a path not in the PR. The tests' fake serves these shapes.

- `pr-status-query.graphql` → `pr-status.json`: each PR in `pr-list.json`'s `mergeable` and head commit's checks, looked up by `nodes(ids:)` as the app does after each refresh (captured 2026-10-14, so the PRs' later state, though each rollup state matched `pr-list.json`'s). A check run's `title` carries Codecov's coverage summary. Some open PRs still answered `UNKNOWN` for `mergeable`, and merged ones always do. The tests' fake serves them.

- `conversation-query.graphql` → `conversation.json`: a PR's conversation as the app asks for it by `node(id:)`, captured on atrium#2928 (7 reviews, 5 threads of which 4 resolved and 2 outdated, replies, comments, force-pushes and commits). The tests' fake serves it, paging its timeline.

## Surprises and shapes

**The timeline leaves out reply-only reviews.** Each reply in a review thread is its own `COMMENTED` review with an empty body, and `timelineItems(itemTypes: [PULL_REQUEST_REVIEW])` returned 2 of atrium#2928's 7 reviews: the one that started the threads and the viewer's `PENDING` one (whose `submittedAt` is null). The replies are only reachable through `reviewThreads { comments }`, so those carry the comment bodies and authors; a review's own `comments` give the path, lines and `diffHunk` of the threads it started. GitHub's timeline does the same, showing replies inside their threads.


**`mergeable` is lazy.** It's `UNKNOWN` on merged PRs and can be `UNKNOWN` on an open PR until GitHub computes it in the background; atrium#2928 (open) returned `MERGEABLE` with `mergeStateStatus: BLOCKED` (awaiting review). The app should treat `UNKNOWN` as "checking" and re-poll, and use `mergeStateStatus` for the reason it can't merge.

**No nulls in the main PR responses.** The nulls appear in review threads: an outdated thread has `line: null` and `startLine: null`, with only `originalLine`/`originalStartLine` set. 10 of 21 recent marmot threads were like that. Outdated threads therefore need the diff of the commit they were made on (`originalCommit`, not yet queried) or should be shown in a list instead of inline.

**`line` is a file line number, not a diff position.** With `diffSide: RIGHT` it's the line in the head version of the file; LEFT means the base version. The comment's `diffHunk` ends on the commented line. A test (`reviewThreadLineIsTheLastLineOfItsDiffHunk`) checks this by parsing the marmot thread's `diffHunk` with the app's parser. This matches the anchor the diff view reports on click: `(path, side, line)`. 3 of 21 threads were on the LEFT side.

**`startLine` is inconsistent for single-line comments.** It's `null` on some single-line comments and equal to `line` on others (8 of 21; the marmot#14569 thread has `startLine == line == 256`). Treat `startLine == nil || startLine == line` as single-line. No `subjectType: FILE` (whole-file) threads appeared, but the field exists and should be handled.

**CI is mostly legacy commit statuses, not check runs.** CircleCI reports as `StatusContext` (`context: "ci/circleci: lint"`, `state`, `targetUrl` to app.circleci.com). Only Codecov uses `CheckRun` (`name`, `status`, `conclusion`, `detailsUrl`). marmot#14569 had 13 statuses and 2 check runs. The `__typename` union has to be handled; the two types have different field names for the same idea (`state` vs `conclusion`, `targetUrl` vs `detailsUrl`). `statusCheckRollup.state` gives an overall status.

**Vendored files do appear in `files`, and they swamp it.** atrium#2912 has `files.totalCount: 741`; the first 100 contained 98 `vendor/` paths. The 4 files a reviewer cares about can sit on a later page, so the app must page through all of `files` (100 per page) before it can show a useful sidebar, or get the file list from git instead. `changeType` includes `RENAMED`. The `PatchStatus` enum also has `COPIED` and `CHANGED` (mode-only), which this PR didn't exercise.

**`viewerViewedState` works** (`UNVIEWED` everywhere here), so "mark file as viewed" can sync with github.com.

**PR conversation comments are mostly bots.** marmot#14569's three top-level `comments` were from shortcut-integration and codecov. Worth collapsing bot authors by default. Review bodies are often empty (`APPROVED` with `body: ""`).

**Inbox search.** 13 results, some old (atrium#2202). `review-requested:@me` and `user-review-requested:@me` both returned 13, so all were direct requests here; team requests would only show up in the former. `search` needs `... on PullRequest` fragments; `reviewDecision` and `isDraft` are available inline, so the inbox needs one query.

**PR list search.** Search returns best-match order unless the query string includes `sort:updated-desc`; with it, truncation at `first: 50` drops the oldest PRs (the author search had 110 results). `reviewDecision` is `null` when the base branch doesn't require reviews, and `commits(last:1).commit.statusCheckRollup` is `null` when the head commit has no statuses or checks.

**Notifications.** The response carries `Last-Modified` (the newest notification's `updated_at`) and `X-Poll-Interval: 60`, and a 304 carries the same poll interval. The 304 left `X-Ratelimit-Remaining` where the 200 before it had put it, so an unchanged poll is free. The token's scopes (`repo`, no `notifications`) were enough: `X-Accepted-Oauth-Scopes` is `notifications, repo`. With `participating=true` all 50 on the first page were `PullRequest` subjects, with reasons `review_requested`, `author`, `state_change` and `mention`; `subject.url` is the REST URL `https://api.github.com/repos/<owner>/<repo>/pulls/<number>`. The list pages at 50 (11 pages here), newest `updated_at` first, and only unread threads are listed by default.

## Diff fixture and vendor exclusion

`git diff <merge-base> <head> -- . ':!vendor' ':!go.sum'` works: on atrium#2912 it cut 741 files to 4, removing 737 (736 under `vendor/` plus `go.sum`), and the diff from 260,541 lines (9 MB) to 205. Two gotchas:

- For a **merged** PR, `git merge-base FETCH_HEAD origin/master` returns the PR head itself (it's already in master), so the diff is empty. Use the API's `baseRefOid` instead: `git merge-base <headRefOid> <baseRefOid>`.
- **`FETCH_HEAD` is shared state.** In a checkout other sessions use, any later fetch (including your own `git fetch origin master`) overwrites it; it did here. Fetch `refs/pull/<N>/head`, then use `headRefOid` from the API rather than `FETCH_HEAD`.

The user's git config has `diff.renames=copies`, so diffs contain `copy from`/`copy to` headers as well as renames; the parser handles both.
