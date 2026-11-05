[(block_comment) (inline_comment) "<!--" "-->"] @comment

[(tag_selector) (parent_selector) (universal_selector)] @tag
[(id_selector) (class_selector) (placeholder_selector) (attribute_name) (pseudo_name)] @attribute
(property_name) @property
(variable_name) @variable
[(module_name) (namespace_name)] @module
(function_name) @function

[(plain_value) (dotted_value) (hash_value) (hex_color) (unicode_range) (keyframes_name)] @constant
[(number) (nth_formula)] @number
(unit) @type.unit
(type_name) @type
[(boolean) (null)] @constant.builtin
[(flag) (important)] @keyword.modifier
(at_keyword) @keyword.directive
(attribute_modifier) @keyword
(operator) @operator.expression
[(attribute_operator) (combinator) (spread)] @operator

; Keyword roles use Neovim names; tree-sitter-highlight matches name parts, so `keyword.function` would render as `function`.
["@use" "@forward" "@import" "as" "show" "hide" "with"] @keyword.import
"@return" @keyword.return
["@if" "@else" "@elseif" "if" "else"] @keyword.conditional
["@each" "@for" "@while" "in" "from" "through" "to"] @keyword.repeat
["@debug" "@warn"] @keyword.debug
"@error" @keyword.exception
["@function" "@mixin" "@include" "@content" "@extend" "@at-root" "using" "returns" "of"] @keyword
["@media" "@supports" "@container" "@scope"
 "@keyframes" "@-webkit-keyframes" "@-moz-keyframes" "@-o-keyframes"
 "@namespace" "@charset" "@layer" "@property"
 "@font-face" "@font-feature-values" "@font-palette-values" "@counter-style"
 "@starting-style" "@view-transition" "@position-try" "@page"] @keyword.directive

; Raw text is punctuation unless it is a URL or holds a word, such as an unevaluated `$name`.
(raw_text) @punctuation.delimiter
(string) @string
(url_value (raw_text) @string)
((raw_text) @string (#match? @string "[A-Za-z0-9]"))
(escape_sequence) @string.escape

["," "|" "."] @punctuation.delimiter

; Context overrides
; Emacs applies this section after base captures, preserving contextual roles.
; Selector prefixes inherit their complete selector capture; pseudo prefixes sit outside the name.
(pseudo_selector [":" "::"] @attribute)
; Query, condition and type operators wrap `|` and retain their structural role.
(operator "|") @operator
(map_entry key: (plain_value) @property)
(keyframes_statement (declaration_block (rule_set (selectors [(tag_selector) @keyword (complex_selector (tag_selector) @keyword)]))))
; A for loop shares `to`, so a scope limit restores its keyword role.
(scope_statement "to" @keyword)
(parameter name: (_) @variable.parameter)
(named_argument name: (variable_name) @variable.parameter)
; A module configuration sets module variables, not parameters.
(configuration (named_argument name: (variable_name) @variable))

(type_annotation ["<" ">"] @punctuation.bracket)
; A wildcard takes the role of the name it stands for.
[(use_statement "*" @module) (forward_statement "*" @module) (namespace_selector "*" @module)]
(type_annotation "*" @type)
(selector_arguments "*" @constant)
(keyframe_selector "%" @type)
(interpolation ["#{" "}"] @punctuation.special)
; A custom `--` name is a variable, even where its property, value, or query feature has a context role.
(dashed_name) @variable
