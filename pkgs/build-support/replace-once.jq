# Replace the literal string $old with $new in raw text read with `--raw-input
# --slurp`, and fail unless $old occurs exactly once. `sub` would treat $old as
# a regular expression, where each `.` in a version tag matches any character.

split($old)
| if length == 2
  then join($new)
  else error("expected exactly one occurrence of \($old), found \(length - 1)")
  end
