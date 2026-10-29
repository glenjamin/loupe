# TreeSitterGoTemplate

The Go template (`text/template`, `html/template`) tree-sitter grammar, vendored because CodeEditLanguages has none.

- Upstream: https://github.com/ngalaiko/tree-sitter-go-template (MIT, see `LICENSE`), the grammar nvim-treesitter and Helix use. It has no tags, so it's pinned to a commit.
- Highlights query: the grammar's own `queries/highlights.scm`
- Version: in `VERSION`, the ref asked for and the commit it resolved to
- Contents: the generated `src/parser.c` and its `src/tree_sitter/parser.h`, and `queries/highlights.scm`, unmodified. The grammar has no C binding, so `include/tree_sitter_gotmpl.h`, declaring its one function, is written by the update script.

Refresh with `Scripts/update-tree-sitter-go-template.sh <commit or branch>`. The parser's `LANGUAGE_VERSION` must be within the range the resolved tree-sitter runtime accepts.
