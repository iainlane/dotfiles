---
name: weekly-update
description: >-
  Write Linear project status updates for the projects the user worked on this
  week. Finds the projects with an update due, confirms which ones to cover,
  gathers the work of the user and their teammates from each project's issues,
  milestones and linked discussions, and posts one update per project after a
  single approval. Use when the user asks for their weekly Linear update.
disable-model-invocation: true
---

# `weekly-update`

Write one Linear project status update for each project that the user worked on
this week, and post it after approval. Every update is posted under the user's
name, but it reports the work of everyone on the project, not only the user's.

Resolve the user at run time from the authenticated Linear identity. Never
hard-code a name, a team, or an identifier.

## Process

1. Unless the plain technical prose output style is already active, invoke the
   `plain-technical-prose` skill before doing anything else. Write every draft
   and every message to the user in that style. The rules under Output and Voice
   add to it for these updates.

2. Set the window: Monday 00:00 local time until now. Not a rolling seven days:
   a Friday afternoon re-run must not pull in the previous Friday.

3. Find the candidate projects. Prefer Linear's own signal: if the project data
   returned by the Linear MCP server marks an update as due or overdue, use
   that. Otherwise list started projects that the user leads or has issues
   assigned in, and treat a project as due when it has no status update since
   the window start. Read each candidate's latest status update so the new one
   can build on it.

4. Show the candidates with one line each: name, status, last update date, and
   why it qualified. Ask which to cover, with all of them as the default. Ask
   with your tool for questions to the user when you have one.

5. For each selected project, gather the activity in the window of everyone
   working on it, the user and teammates alike, across the project's issues,
   including issues grouped under its milestones: issues completed, issues
   created, state changes, and substantive comments. An issue counts only when a
   person acted on it in the window; a change made by an automation does not.
   Note each issue's milestone, and pull in linked pull requests where they show
   what actually happened. Teammates' measurements and investigations count as
   work: read them from issue comments and, through the Slack MCP server, from
   Slack threads that the project's issues link to.

6. Split the gathered work into non-trivial and trivial. Non-trivial work
   changed something a reader of the update cares about: a feature landed, a
   decision made, a blocker cleared, a milestone moved. Trivial work is routine:
   small fixes, review-only touches, housekeeping. Drop trivial work, unless
   there is enough of it to matter, in which case collect all of it into one
   closing bullet ("plus n small fixes: …").

7. Compose one update per project, using the shape under Output: a short
   high-level paragraph, then the non-trivial work as bullets, with a line of
   connecting prose between groups where that reads better.

8. Review each draft with a fresh subagent that starts without this session's
   context. Give it the prompt under Review with the placeholders filled in, and
   nothing else: none of the issues, pull requests or conversation behind the
   draft. Review the drafts in parallel when there are several. Revise each
   draft to address every finding. If a fix would make a statement inaccurate,
   keep the statement and report the finding to the user at the approval gate.

9. Show every draft in full in a message, then ask for approval in the same way
   as in step 4. The user may approve, or reply with changes and iterate with
   you on the text. Do not post until the user explicitly approves the final
   text. Then post each update with the Linear MCP server's `save_status_update`
   tool and `type: "project"`. Pass the previous update's health unchanged. For
   a project without a previous update, ask the user to choose its health at the
   gate. Never pick a health yourself; change an existing health only when the
   user asks for a change at the gate.

10. Report each project with the URL of its posted update.

## Output

The update body is a high-level summary of two to four sentences, then one
bullet per piece of non-trivial work, then any closing line that the reader
needs (remaining work, or the main risk to the target). The summary is
judgement, not the bullets restated in sentence form: say what the week added up
to. Bullets lead with what changed, never with an issue key, and link PRs and
issues inline on the phrase that they substantiate.

Open with the week's outcome stated as a fact. When the week went badly, say
what happened and what it means for the target, and leave out any judgement of
how bad it is: an opening such as "how little of it can work" is too gloomy.

Name the main remaining issue plainly in the closing line. If someone has
proposed a way out that nobody has tried yet, describe it and mark it as "to
explore" so the reader can tell it apart from a decided plan.

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
sentences, it contains detail that belongs in a bullet or nowhere.

## Review

The reviewing subagent gets this prompt, with each `{…}` placeholder replaced:

```text
Write this review in the plain technical prose style. If the rules of that
style are not already in your instructions, invoke the `plain-technical-prose`
skill first.

Review the draft in the <draft> tags. It is a weekly status update for the
Linear project {project name}, and it will be posted for readers across the
company. Read it as an experienced software engineer who does not work on this
project. You have not seen the issues, pull requests or discussions behind the
draft, and you should not look them up: judge the update from its text alone.

Report every passage that has one of these problems:

- You cannot follow it without knowing the project's internals, or it uses a
  term or abbreviation that the update does not explain.
- It claims progress without a link or a concrete change in behaviour.
- It only shows effort: review rounds, rebases, conflict fixes, or test and CI
  maintenance.
- The opening sentence is vague or gloomy, or it does not state the week's
  outcome.
- The remaining issue is hinted at but not named, or an untried proposal reads
  as a decided plan.
- It breaks a rule of the plain technical prose style.

Report each finding in the audit-report form from that style. Do not rewrite
the update. If you find no problems, reply that the draft has none.

The <previous_update> tags contain the project's previous update. It shows what
readers already know, and it is not under review.

<draft>
{draft}
</draft>

<previous_update>
{previous update}
</previous_update>
```

## Constraints

- Stop for the user only at the project selection and at the approval gate.
- This skill posts project status updates and nothing else. It mutates no issue,
  changes no project field, and writes to no other system.
