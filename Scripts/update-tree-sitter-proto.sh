#!/bin/sh
# Refreshes the vendored Protocol Buffers grammar from coder3101/tree-sitter-proto.
# Usage: Scripts/update-tree-sitter-proto.sh 0.6.0
#
# Only the generated C parser, its headers, the highlights query and the
# licence are copied; nothing from the download is built or run.
set -eu

ref=${1:?usage: $0 <tree-sitter-proto tag or commit, e.g. 0.6.0>}
repo=coder3101/tree-sitter-proto
dir=Sources/TreeSitterProto
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

commit=$(gh api "repos/$repo/commits/$ref" --jq .sha)
curl -fsSL "https://codeload.github.com/$repo/tar.gz/$commit" | tar -xz -C "$tmp" --strip-components 1

mkdir -p "$dir/src/tree_sitter" "$dir/include" "$dir/queries"
cp "$tmp/src/parser.c" "$dir/src/parser.c"
cp "$tmp/src/tree_sitter/alloc.h" "$tmp/src/tree_sitter/array.h" "$tmp/src/tree_sitter/parser.h" "$dir/src/tree_sitter/"
cp "$tmp/bindings/c/tree-sitter-proto.h" "$dir/include/tree_sitter_proto.h"
cp "$tmp/queries/highlights.scm" "$dir/queries/highlights.scm"
cp "$tmp/LICENSE" "$dir/LICENSE"
echo "$ref $commit" > "$dir/VERSION"

abi=$(sed -n 's/^#define LANGUAGE_VERSION //p' "$dir/src/parser.c")
echo "tree-sitter-proto $ref ($commit), ABI $abi, written to $dir"
echo "Check ABI $abi is within the tree-sitter runtime's range in .build/checkouts/tree-sitter/lib/include/tree_sitter/api.h"
