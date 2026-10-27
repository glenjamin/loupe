#!/bin/sh
# Refreshes the vendored HCL grammar from tree-sitter-grammars/tree-sitter-hcl, and
# its highlights query from nvim-treesitter, as the grammar ships none.
# Usage: Scripts/update-tree-sitter-hcl.sh v1.2.0 [nvim-treesitter commit]
#
# Only the generated C parser and scanner, their headers, the highlights query and
# the licences are copied; nothing from the downloads is built or run.
set -eu

ref=${1:?usage: $0 <tree-sitter-hcl tag or commit, e.g. v1.2.0> [nvim-treesitter ref]}
queries_ref=${2:-main}
repo=tree-sitter-grammars/tree-sitter-hcl
queries_repo=nvim-treesitter/nvim-treesitter
dir=Sources/TreeSitterHCL
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

commit=$(gh api "repos/$repo/commits/$ref" --jq .sha)
curl -fsSL "https://codeload.github.com/$repo/tar.gz/$commit" | tar -xz -C "$tmp" --strip-components 1
queries_commit=$(gh api "repos/$queries_repo/commits/$queries_ref" --jq .sha)
mkdir -p "$tmp/nvim"
curl -fsSL "https://raw.githubusercontent.com/$queries_repo/$queries_commit/runtime/queries/hcl/highlights.scm" -o "$tmp/nvim/highlights.scm"
curl -fsSL "https://raw.githubusercontent.com/$queries_repo/$queries_commit/LICENSE" -o "$tmp/nvim/LICENSE"

mkdir -p "$dir/src/tree_sitter" "$dir/include" "$dir/queries"
cp "$tmp/src/parser.c" "$tmp/src/scanner.c" "$dir/src/"
cp "$tmp/src/tree_sitter/alloc.h" "$tmp/src/tree_sitter/array.h" "$tmp/src/tree_sitter/parser.h" "$dir/src/tree_sitter/"
cp "$tmp/bindings/c/tree_sitter/tree-sitter-hcl.h" "$dir/include/tree_sitter_hcl.h"
cp "$tmp/nvim/highlights.scm" "$dir/queries/highlights.scm"
cp "$tmp/LICENSE" "$dir/LICENSE"
cp "$tmp/nvim/LICENSE" "$dir/LICENSE-queries"
printf '%s %s\nnvim-treesitter %s\n' "$ref" "$commit" "$queries_commit" > "$dir/VERSION"

abi=$(sed -n 's/^#define LANGUAGE_VERSION //p' "$dir/src/parser.c")
echo "tree-sitter-hcl $ref ($commit), queries from nvim-treesitter $queries_commit, ABI $abi, written to $dir"
echo "Check ABI $abi is within the tree-sitter runtime's range in .build/checkouts/tree-sitter/lib/include/tree_sitter/api.h"
