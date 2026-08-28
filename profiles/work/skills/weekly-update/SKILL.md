---
name: weekly-update
description: >-
  Write Linear project status updates for the projects the user worked on this
  week. Finds the projects with an update due, confirms which ones to cover,
  gathers the user's work from each project's issues and milestones, and posts
  one update per project after a single approval.
disable-model-invocation: true
---

# `weekly-update`

Write one Linear project status update per project the user worked on this week,
and post it after approval. Everything publishes under the user's name.

Resolve the user at run time from the authenticated Linear identity. Never
hard-code a name, a team, or an identifier.

## Process

1. Set the window: Monday 00:00 local time until now. Not a rolling seven days:
   a Friday afternoon re-run must not pull in the previous Friday.

2. Find the candidate projects. Prefer Linear's own signal: if the project data
   the MCP returns marks an update as due or overdue, use that. Otherwise list
   started projects the user leads or has issues assigned in, and treat a
   project as due when it has no status update since the window start. Read each
   candidate's latest status update so the new one can build on it.

3. Show the candidates with one line each: name, status, last update date, and
   why it qualified. Ask which to cover, with all of them as the default. This
   is the first of the two questions this skill asks.

4. For each selected project, gather the user's activity in the window across
   the project's issues, including issues grouped under its milestones: issues
   completed, issues created, state changes, and substantive comments. An issue
   counts only when the user acted on it in the window; a touch from an
   automation or another person does not. Note each issue's milestone, and pull
   in linked pull requests where they show what actually happened.

5. Split the gathered work into non-trivial and trivial. Non-trivial work
   changed something a reader of the update cares about: a feature landed, a
   decision made, a blocker cleared, a milestone moved. Trivial work is routine:
   small fixes, review-only touches, housekeeping. Drop trivial work, unless
   there is enough of it to matter, in which case collect all of it into one
   closing bullet ("plus n small fixes: …").

6. Compose one update per project, using the shape under Output: a short
   high-level paragraph, then the non-trivial work as bullets, with a line of
   connecting prose between groups where that reads better.

7. Show every draft and ask for approval. On approval, post each update with
   `save_status_update` and `type: "project"`, passing the previous update's
   health unchanged. Never pick a health yourself; change it only when the user
   asks for a change at the gate. The user may iterate with you on the text at
   this point. Do not post until the user explicitly approves the final text.

8. Report each project with the URL of its posted update.

## Output

The update body is a high-level summary of two to four sentences, then one
bullet per piece of non-trivial work, then any closing line the reader needs
(remaining work, or the main variable to the target). The summary is judgement,
not the bullets restated in sentence form: say what the week added up to.
Bullets lead with what changed, never with an issue key, and link PRs and issues
inline on the phrase they substantiate.

An update in the expected shape:

```markdown
Report exports are in. Staging now generates the CSV and PDF exports on demand,
alongside the scheduled nightly run
([the priority from last week](https://github.com/example/monorepo/pull/1234)).
This unblocks the retention work, which needs on-demand exports so nothing is
lost when old rows are pruned. All exports pass through the redaction filter
before leaving the service.

This resulted in some bugs, which we fixed:

- Exports whose job is killed abnormally (for example a superseded run) now
  report a `cancelled` conclusion to the API. Staging had
  [exports shown as running days after their jobs died](https://github.com/example/monorepo/pull/1240).
- The
  [HTTP metrics middleware was breaking streaming responses](https://github.com/example/monorepo/pull/1241),
  which cut large downloads short; fixed and verified in staging.

In the UI, we added
[screen-reader support to the export dialog](https://github.com/example/monorepo/pull/1236)
and a
[progress indicator for long exports](https://github.com/example/monorepo/pull/1238),
so a slow export no longer looks like a hang.
```

## Voice

British spelling. No hedging, no sign-off, no headings inside the body, no
bold-label bullets. Cut anything that only proves diligence: the reader wants
what changed, not evidence of effort. If the summary does not fit in four
sentences, it is carrying detail that belongs in a bullet or nowhere.

## Constraints

- Ask at least twice: the project selection, and the approval gate.
- Health carries forward from the previous update. Only the user changes it.
- This skill posts project status updates and nothing else. It mutates no issue,
  changes no project field, and touches no other system.
