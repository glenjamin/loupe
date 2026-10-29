#!/bin/sh
# Refreshes the vendored GraphQL grammar and its highlights query from
# bkegley/tree-sitter-graphql, the grammar nvim-treesitter and Helix use.
# Usage: Scripts/update-tree-sitter-graphql.sh 5e66e961eee421786bdda8495ed1db045e06b5fe
#
# Only the generated C parser, its header, the highlights query and the licence
# are copied; nothing from the download is built or run. The grammar has no C
# binding, so its one-function header is written here.
set -eu

ref=${1:?usage: $0 <tree-sitter-graphql commit or branch, e.g. master>}
repo=bkegley/tree-sitter-graphql
dir=Sources/TreeSitterGraphQL
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

commit=$(gh api "repos/$repo/commits/$ref" --jq .sha)
curl -fsSL "https://codeload.github.com/$repo/tar.gz/$commit" | tar -xz -C "$tmp" --strip-components 1

mkdir -p "$dir/src/tree_sitter" "$dir/include" "$dir/queries"
cp "$tmp/src/parser.c" "$dir/src/parser.c"
cp "$tmp/src/tree_sitter/parser.h" "$dir/src/tree_sitter/"
cp "$tmp/queries/graphql/highlights.scm" "$dir/queries/highlights.scm"
cp "$tmp/LICENSE" "$dir/LICENSE"
cat > "$dir/include/tree_sitter_graphql.h" <<'EOF'
#ifndef TREE_SITTER_GRAPHQL_H_
#define TREE_SITTER_GRAPHQL_H_

typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_graphql(void);

#ifdef __cplusplus
}
#endif

#endif // TREE_SITTER_GRAPHQL_H_
EOF
echo "$ref $commit" > "$dir/VERSION"

abi=$(sed -n 's/^#define LANGUAGE_VERSION //p' "$dir/src/parser.c")
echo "tree-sitter-graphql $ref ($commit), ABI $abi, written to $dir"
echo "Check ABI $abi is within the tree-sitter runtime's range in .build/checkouts/tree-sitter/lib/include/tree_sitter/api.h"
