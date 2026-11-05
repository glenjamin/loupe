# TreeSitterSCSS

The SCSS tree-sitter grammar, vendored because CodeEditLanguages has none.

- Upstream: https://github.com/P233/tree-sitter-scss (MIT, see `LICENSE`), written from scratch rather than extending tree-sitter-css, and parsing Sass modules, maps and nested properties that tree-sitter-grammars/tree-sitter-scss misreads.
- Highlights query: the grammar's own `queries/highlights.scm`, which covers CSS as well as SCSS.
- Version: in `VERSION`, the ref asked for and the commit it resolved to
- Contents: the generated `src/parser.c`, the external `src/scanner.c` and their `src/tree_sitter` headers, and `queries/highlights.scm`, unmodified. The grammar has no C binding, so the update script writes `include/tree_sitter_scss.h`, declaring its SCSS entry point.

Refresh with `Scripts/update-tree-sitter-scss.sh <commit, tag or branch>`. The parser's `LANGUAGE_VERSION` must be within the range the resolved tree-sitter runtime accepts.
