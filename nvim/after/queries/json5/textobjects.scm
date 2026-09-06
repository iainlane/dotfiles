; extends

; @comment.outer: the whole comment node, delimiters included.
(comment) @comment.outer


; @comment.inner: only the text inside the delimiters. Capture the whole
; comment, then move its ends past the delimiters with `#offset!`.

; Line comments (// ...): skip the leading `// `.
((comment) @comment.inner
  (#match? @comment.inner "^//")
  (#offset! @comment.inner 0 3 0 0))

; Block comments (/* ... */): skip `/*` at the start and `*/` at the end.
((comment) @comment.inner
  (#match? @comment.inner "^/\\*")
  (#offset! @comment.inner 0 2 0 -2))
