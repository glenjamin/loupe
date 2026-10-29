#!/bin/sh
# Refreshes the vendored Go template grammar and its highlights query from
# ngalaiko/tree-sitter-go-template, the grammar nvim-treesitter and Helix use.
# Usage: Scripts/update-tree-sitter-go-template.sh 06b2fd2ac32a7be71cdcf925eeeb868a68e2acde
#
# Only the generated C parser, its header, the highlights query and the licence
# are copied; nothing from the download is built or run. The grammar has no C
# binding, so its one-function header is written here.
set -eu

ref=${1:?usage: $0 <tree-sitter-go-template commit or branch, e.g. master>}
repo=ngalaiko/tree-sitter-go-template
dir=Sources/TreeSitterGoTemplate
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

commit=$(gh api "repos/$repo/commits/$ref" --jq .sha)
curl -fsSL "https://codeload.github.com/$repo/tar.gz/$commit" | tar -xz -C "$tmp" --strip-components 1

mkdir -p "$dir/src/tree_sitter" "$dir/include" "$dir/queries"
cp "$tmp/src/parser.c" "$dir/src/parser.c"
cp "$tmp/src/tree_sitter/parser.h" "$dir/src/tree_sitter/"
cp "$tmp/queries/highlights.scm" "$dir/queries/highlights.scm"
cp "$tmp/LICENSE" "$dir/LICENSE"
cat > "$dir/include/tree_sitter_gotmpl.h" <<'HEADER'
#ifndef TREE_SITTER_GOTMPL_H_
#define TREE_SITTER_GOTMPL_H_

typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_gotmpl(void);

#ifdef __cplusplus
}
#endif

#endif // TREE_SITTER_GOTMPL_H_
HEADER
echo "$ref $commit" > "$dir/VERSION"

abi=$(sed -n 's/^#define LANGUAGE_VERSION //p' "$dir/src/parser.c")
echo "tree-sitter-go-template $ref ($commit), ABI $abi, written to $dir"
echo "Check ABI $abi is within the tree-sitter runtime's range in .build/checkouts/tree-sitter/lib/include/tree_sitter/api.h"
