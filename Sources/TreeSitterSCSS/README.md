# TreeSitterSCSS

The SCSS tree-sitter grammar, vendored because CodeEditLanguages has none.

- Upstream: https://github.com/tree-sitter-grammars/tree-sitter-scss (MIT, see `LICENSE`), the maintained successor to serenadeai/tree-sitter-scss. Its one tag predates its licence file, so it's pinned to a commit.
- Highlights query: the grammar's own `queries/highlights.scm`, which covers SCSS's additions to CSS; the highlighter puts CodeEditLanguages' CSS query beneath it.
- Version: in `VERSION`, the ref asked for and the commit it resolved to
- Contents: the generated `src/parser.c`, the external `src/scanner.c` and their `src/tree_sitter` headers, the C binding's header as `include/tree_sitter_scss.h`, and `queries/highlights.scm`, unmodified.

Refresh with `Scripts/update-tree-sitter-scss.sh <commit, tag or branch>`. The parser's `LANGUAGE_VERSION` must be within the range the resolved tree-sitter runtime accepts.
