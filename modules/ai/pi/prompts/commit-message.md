---
description: Draft a commit message for the current changes
argument-hint: "[focus]"
model: claude-sonnet-4-6
thinking: low
---

# Draft commit message

Draft a commit message for the current repository changes.

Inspect the latest commit history and the staged and unstaged diffs. If I
provided a focus, reflect it: $@

Write the message in the style of this repository. Explain why the change is
needed, not just what changed. Wrap the subject and body at 72 characters. Do
not create the commit unless I explicitly ask.
