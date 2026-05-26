---
description: Run relevant checks and fix failures
argument-hint: "[check command or focus]"
model: claude-sonnet-4-6
thinking: high
---

# Fix checks

Run the relevant project checks, then fix the failures.

If I provided a command or focus, start there: $@

First identify the project's normal verification commands from its README,
justfile, package scripts, Cargo metadata, flake outputs, or equivalent. Prefer
the narrowest checks that cover the current change, then run broader checks once
the fix is ready.

Keep going until the checks pass or you are blocked by something outside this
repository. If blocked, explain the exact command, the failure, and the next
action needed.
