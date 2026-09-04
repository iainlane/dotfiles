---
description: Review staged git changes before committing
argument-hint: "[focus]"
model: claude-sonnet-4-6
thinking: medium
---

# Review staged changes

Review the staged changes in this repository.

Use `git diff --cached` and any relevant project context. Focus on bugs,
security issues, error handling, test coverage, and whether the change fits the
existing style.

If an argument is provided, give that extra attention: $@

Do not change files unless I explicitly ask you to. Return findings grouped by
severity, and include a short "ready to commit" judgement.
