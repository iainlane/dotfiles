---
description: Review a change with several independent reviewer subagents
argument-hint: "[focus]"
model: claude-sonnet-4-6
thinking: medium
subagent: reviewer
inheritContext: true
parallel: 3
---

# Parallel review

Review the current change independently.

Focus on correctness, regressions, missing tests, security issues,
maintainability, and whether the implementation fits the project. If I provided
a focus, give it extra attention: $@

Do not edit files. Return concrete findings with file paths and suggested fixes.
