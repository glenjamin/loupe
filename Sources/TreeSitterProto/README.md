# TreeSitterProto

The Protocol Buffers tree-sitter grammar, vendored because CodeEditLanguages has none.

- Upstream: https://github.com/coder3101/tree-sitter-proto (MIT, see `LICENSE`)
- Version: in `VERSION`, as tag and commit
- Contents: the generated `src/parser.c` and its `src/tree_sitter` headers, the C binding's header as `include/tree_sitter_proto.h`, and `queries/highlights.scm`, unmodified.

Refresh with `Scripts/update-tree-sitter-proto.sh <tag or commit>`. The parser's `LANGUAGE_VERSION` must be within the range the resolved tree-sitter runtime accepts.
