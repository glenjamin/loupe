# TreeSitterHCL

The HCL tree-sitter grammar, for Terraform and other HCL files, vendored because CodeEditLanguages has none.

- Upstream: https://github.com/tree-sitter-grammars/tree-sitter-hcl (Apache-2.0, see `LICENSE`)
- Highlights query: nvim-treesitter's `runtime/queries/hcl/highlights.scm`, as the grammar ships none (Apache-2.0, see `LICENSE-queries`)
- Version: in `VERSION`, the grammar's tag and commit, then the nvim-treesitter commit
- Contents: the generated `src/parser.c`, the external `src/scanner.c` and their `src/tree_sitter` headers, the C binding's header as `include/tree_sitter_hcl.h`, and `queries/highlights.scm`, unmodified.

Refresh with `Scripts/update-tree-sitter-hcl.sh <tag or commit> [nvim-treesitter commit]`. The parser's `LANGUAGE_VERSION` must be within the range the resolved tree-sitter runtime accepts.
