# TreeSitterMake

The Makefile tree-sitter grammar, vendored because CodeEditLanguages has none.

- Upstream: https://github.com/tree-sitter-grammars/tree-sitter-make (MIT, see `LICENSE`), the grammar nvim-treesitter uses. Pinned to the commit nvim-treesitter pins, which is newer than the last tag and the first to carry the licence file.
- Highlights query: the grammar's own `queries/highlights.scm`, synced from nvim-treesitter's
- Version: in `VERSION`, the ref asked for and the commit it resolved to
- Contents: the generated `src/parser.c` and its `src/tree_sitter/parser.h`, the C binding's header as `include/tree_sitter_make.h`, and `queries/highlights.scm`, unmodified.

Refresh with `Scripts/update-tree-sitter-make.sh <commit, tag or branch>`. The parser's `LANGUAGE_VERSION` must be within the range the resolved tree-sitter runtime accepts.
