#!/bin/sh
# Refreshes the vendored Makefile grammar and its highlights query from
# tree-sitter-grammars/tree-sitter-make, the grammar nvim-treesitter uses.
# Usage: Scripts/update-tree-sitter-make.sh 70613f3d812cbabbd7f38d104d60a409c4008b43
#
# Only the generated C parser, its header and C binding, the highlights query and
# the licence are copied; nothing from the download is built or run.
set -eu

ref=${1:?usage: $0 <tree-sitter-make tag, commit or branch, e.g. main>}
repo=tree-sitter-grammars/tree-sitter-make
dir=Sources/TreeSitterMake
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

commit=$(gh api "repos/$repo/commits/$ref" --jq .sha)
curl -fsSL "https://codeload.github.com/$repo/tar.gz/$commit" | tar -xz -C "$tmp" --strip-components 1

mkdir -p "$dir/src/tree_sitter" "$dir/include" "$dir/queries"
cp "$tmp/src/parser.c" "$dir/src/"
cp "$tmp/src/tree_sitter/parser.h" "$dir/src/tree_sitter/"
cp "$tmp/bindings/c/tree_sitter/tree-sitter-make.h" "$dir/include/tree_sitter_make.h"
cp "$tmp/queries/highlights.scm" "$dir/queries/highlights.scm"
cp "$tmp/LICENSE" "$dir/LICENSE"
echo "$ref $commit" > "$dir/VERSION"

abi=$(sed -n 's/^#define LANGUAGE_VERSION //p' "$dir/src/parser.c")
echo "tree-sitter-make $ref ($commit), ABI $abi, written to $dir"
echo "Check ABI $abi is within the tree-sitter runtime's range in .build/checkouts/tree-sitter/lib/include/tree_sitter/api.h"
