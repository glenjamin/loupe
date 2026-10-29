#!/bin/sh
# Refreshes the vendored SCSS grammar and its highlights query from
# tree-sitter-grammars/tree-sitter-scss. Its query adds SCSS's syntax to CSS's,
# which the highlighter takes from CodeEditLanguages.
# Usage: Scripts/update-tree-sitter-scss.sh 5da5ba71a558b007b352c505bfcd9095ae337022
#
# Only the generated C parser and scanner, their headers, the highlights query and
# the licence are copied; nothing from the download is built or run.
set -eu

ref=${1:?usage: $0 <tree-sitter-scss tag, commit or branch, e.g. master>}
repo=tree-sitter-grammars/tree-sitter-scss
dir=Sources/TreeSitterSCSS
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

commit=$(gh api "repos/$repo/commits/$ref" --jq .sha)
curl -fsSL "https://codeload.github.com/$repo/tar.gz/$commit" | tar -xz -C "$tmp" --strip-components 1

mkdir -p "$dir/src/tree_sitter" "$dir/include" "$dir/queries"
cp "$tmp/src/parser.c" "$tmp/src/scanner.c" "$dir/src/"
cp "$tmp/src/tree_sitter/alloc.h" "$tmp/src/tree_sitter/array.h" "$tmp/src/tree_sitter/parser.h" "$dir/src/tree_sitter/"
cp "$tmp/bindings/c/tree_sitter/tree-sitter-scss.h" "$dir/include/tree_sitter_scss.h"
cp "$tmp/queries/highlights.scm" "$dir/queries/highlights.scm"
cp "$tmp/LICENSE" "$dir/LICENSE"
echo "$ref $commit" > "$dir/VERSION"

abi=$(sed -n 's/^#define LANGUAGE_VERSION //p' "$dir/src/parser.c")
echo "tree-sitter-scss $ref ($commit), ABI $abi, written to $dir"
echo "Check ABI $abi is within the tree-sitter runtime's range in .build/checkouts/tree-sitter/lib/include/tree_sitter/api.h"
