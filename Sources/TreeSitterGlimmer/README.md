# TreeSitterGlimmer

The Glimmer tree-sitter grammar, Ember's dialect of Handlebars, vendored for Handlebars templates because CodeEditLanguages has none.

- Upstream: https://github.com/ember-tooling/tree-sitter-glimmer (MIT, see `LICENSE`, upstream's `LICENSE.md`), the grammar nvim-treesitter uses for Handlebars. Pinned to the commit nvim-treesitter pins, a few fixes past the last tag.
- Highlights query: the grammar's own `queries/glimmer/highlights.scm`
- Version: in `VERSION`, the ref asked for and the commit it resolved to
- Contents: the generated `src/parser.c`, the external `src/scanner.c` and their `src/tree_sitter/parser.h`, the C binding's header as `include/tree_sitter_glimmer.h`, and `queries/highlights.scm`, unmodified.

Refresh with `Scripts/update-tree-sitter-glimmer.sh <commit, tag or branch>`. The parser's `LANGUAGE_VERSION` must be within the range the resolved tree-sitter runtime accepts.
