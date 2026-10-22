# Loupe

A native macOS app for reviewing GitHub pull requests. It shows your open PRs beside those waiting on your review, and diffs each PR from your local checkout of its repo, so vendored and generated files stay out of the way and large PRs stay fast.

It's built for one person's workflow and shared as is.

## Requirements

- macOS 14 or later
- Swift 6 (the Command Line Tools are enough; Xcode isn't needed)
- The [GitHub CLI](https://cli.github.com), signed in with `gh auth login`; Loupe uses its token
- Local git checkouts of the repos you review

## Running

```sh
./start.sh          # builds .build/Loupe.app and opens it
./start.sh release  # an optimised build
```

On first launch Loupe asks which folders your checkouts are in, and looks in each for a directory named after a PR's repo. The choice is kept in `~/.config/loupe/config.json`, which you can edit by hand, and can be changed from Loupe ▸ Checkout Folders…. Loupe only reads from checkouts, apart from fetching PR heads into its own `refs/loupe/` refs and cloning a repo you ask it to.

## Developing

```sh
swift build
swift test
Scripts/ui-tests.sh  # drives the app off-screen against a fake GitHub
```

`DESIGN.md` explains the goals and the reasons behind each decision; `NOTES.md` covers building, debugging and the UI test scripts in more depth.
