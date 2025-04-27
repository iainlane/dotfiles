; extends

; @comment.outer
; Matches the entire comment node, including the delimiters (// or /* */)
; The (comment) node itself covers the full range including delimiters.
(comment) @comment.outer


; @comment.inner
; Matches only the content *inside* the comment delimiters.
; We capture the whole comment first, then use predicates to adjust the range.

; Handle line comments (// ...)
((comment) @comment.inner
  (#match? @comment.inner "^//") ; Check if the comment starts with //
  ; Offset start by 3 columns (to skip `// `), leave end unchanged
  (#offset! @comment.inner 0 3 0 0))

; Handle block comments (/* ... */)
((comment) @comment.inner
  (#match? @comment.inner "^/\\*") ; Check if the comment starts with /*
  ; Offset start by 2 columns (to skip /*)
  ; Offset end back by 2 columns (to skip */)
  (#offset! @comment.inner 0 2 0 -2))
