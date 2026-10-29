#!/bin/sh
# Refreshes the vendored Glimmer grammar, for Handlebars templates, and its
# highlights query from ember-tooling/tree-sitter-glimmer, the grammar
# nvim-treesitter uses for Handlebars.
# Usage: Scripts/update-tree-sitter-glimmer.sh c67a73679db2945a686ca45d3e5318d86138e72a
#
# Only the generated C parser and scanner, their header, the C binding's header,
# the highlights query and the licence are copied; nothing from the download is
# built or run.
set -eu

ref=${1:?usage: $0 <tree-sitter-glimmer tag, commit or branch, e.g. main>}
repo=ember-tooling/tree-sitter-glimmer
dir=Sources/TreeSitterGlimmer
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

commit=$(gh api "repos/$repo/commits/$ref" --jq .sha)
curl -fsSL "https://codeload.github.com/$repo/tar.gz/$commit" | tar -xz -C "$tmp" --strip-components 1

mkdir -p "$dir/src/tree_sitter" "$dir/include" "$dir/queries"
cp "$tmp/src/parser.c" "$tmp/src/scanner.c" "$dir/src/"
cp "$tmp/src/tree_sitter/parser.h" "$dir/src/tree_sitter/"
cp "$tmp/bindings/c/tree_sitter/tree-sitter-glimmer.h" "$dir/include/tree_sitter_glimmer.h"
cp "$tmp/queries/glimmer/highlights.scm" "$dir/queries/highlights.scm"
cp "$tmp/LICENSE.md" "$dir/LICENSE"
echo "$ref $commit" > "$dir/VERSION"

abi=$(sed -n 's/^#define LANGUAGE_VERSION //p' "$dir/src/parser.c")
echo "tree-sitter-glimmer $ref ($commit), ABI $abi, written to $dir"
echo "Check ABI $abi is within the tree-sitter runtime's range in .build/checkouts/tree-sitter/lib/include/tree_sitter/api.h"
