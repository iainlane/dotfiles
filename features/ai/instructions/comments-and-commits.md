# Comments and commit messages

Whichever output style is active governs how you word prose. These rules govern
what belongs in a code comment and what belongs in a commit message, and they
apply to every session.

## Comments and documentation

Match the repository's existing comment density. When the surrounding file
rarely comments individual settings or expressions, do not add comments merely
because the reason for a change is non-obvious.

Before adding or retaining a comment, distinguish **review rationale** from
**maintenance information**.

Review rationale explains this change: what was broken before, what
investigation found, why this patch chose one implementation, or why an
alternative was rejected. That information usually belongs in the commit
message, not beside the resulting code.

Maintenance information explains a hidden constraint in the resulting code. It
belongs beside the code only when the code invites a plausible, apparently
harmless edit that would be wrong for a reason the code itself cannot show.

**A line is not comment-worthy merely because removing or changing it would
reintroduce a bug.** That is true of almost every line in a bug fix.

For every comment you are about to add or retain, apply these tests in order:

1. **Does the surrounding file normally comment code at this level?** If not,
   start from the assumption that no comment is needed.

2. **Does the comment mostly explain this commit?** If it explains what used to
   be wrong, how the problem was diagnosed, why this patch was made, or why the
   chosen code fixes it, put that information in the commit message instead.

3. **Is the resulting code itself ordinary and unsurprising?** An explicit
   configuration value, function call, branch, or argument usually does not need
   a comment just because another value would behave differently.

4. **Does the code invite a specific plausible edit that looks simpler, more
   idiomatic, or more obvious?** If not, omit the comment.

5. **Would that plausible edit be wrong because of a hidden constraint?** If
   yes, comment only on that hidden constraint and why the tempting alternative
   fails.

An explicit non-default setting normally does not need a comment merely to
explain why its value is important:

```text
UNNECESSARY:
# This mode is required because the default treats the value differently.
mode = "exact";

BETTER:
mode = "exact";
```

A comment is useful when a superficially cleaner implementation would violate a
hidden constraint:

```text
USEFUL:
# Keep the temporary file beside the destination so the rename stays atomic.
temporaryDirectory = outputDirectory;
```

Keep the maintenance constraint, not the history of the investigation.

Comments are not miniature commit messages. A useful distinction is:

- **"Why did this commit change this?"** Usually answer that in the commit
  message.
- **"Why does this strange-looking code need to stay strange-looking?"** If the
  code cannot answer that itself, and a maintainer could plausibly simplify it
  incorrectly, a short comment may be appropriate.

Prefer the shortest comment that prevents the likely wrong edit.

Explain retained comments literally. A future reader must understand them
without knowing the task, the prompt, the conversation, or how the
implementation was discovered. Do not narrate the code line by line, and do not
expand a short maintenance constraint into an essay.

## Commit messages

A commit message is pedagogical: it leads the reader from the problem to the
solution and gives them the understanding they need to follow it. The same
standard applies to the contents of the commit, judged as a whole and in the
context of the surrounding code, not only to the message.

Follow the repository's subject style, formatting, and usual level of detail.

Write the commit message for a maintainer reading `git log` months later,
without the conversation, issue discussion, or investigation that led to the
change.

For every non-trivial change, the message **must make the reason for the change
understandable**.

Include the facts needed to answer the relevant questions:

- What was wrong, missing, or unnecessarily difficult before?
- What caused that behaviour, when the cause is not obvious?
- What changed?
- Why does that change address the problem?
- Is there an important exception, consequence, or verification result that a
  future maintainer needs to know?

Do not mechanically answer every question. Include the ones that matter for the
change.

A useful default narrative order is: problem, then cause, then change, then
result.

This is a guide to the information flow, not a required paragraph template.
Combine, reorder, or omit parts when that makes the explanation more natural.

The freedom is in the composition, not in whether a non-trivial commit explains
its reason.

Prefer concrete before-and-after behaviour over general statements such as
"improve handling", "make more robust", or "clean up".

Explain implementation details only when they are needed to understand why the
change works or why it was made this way. Do not turn the commit message into a
walkthrough of the diff.

Record useful verification when it adds evidence beyond "the tests pass": for
example, a reproduced failure that now succeeds, a benchmark result, or the
observed behaviour of an external tool before and after the change.

Keep investigation chronology out unless the order of events itself matters.
Write the conclusion the investigation established, not the sequence of things
tried along the way.

Do not force a long body for a self-explanatory change such as a mechanical
rename, formatting change, routine lock-file update, or similarly obvious patch.

Conversely, do not shorten a complex commit merely to make it look concise. If
its reason requires several paragraphs, use them.

Put review and historical rationale in the commit message rather than in code
comments when that information helps explain the change but is not a constraint
on the resulting code.

### Commit-message examples

Too little information:

```text
add index to the foo table
```

Still too little:

```text
fix(db): add an index to the foo table

Add an index to `foo.quux` and add a benchmark.
```

The second message describes the diff but does not explain why the index is
needed.

A useful message:

```text
fix(db): index foo by quux

Requests for the bar page fetch every baz for one quux. The query was
scanning the whole foo table on each request, and latency became
noticeable as the table grew.

Add an index on foo.quux so the database can find those rows directly.
On the 1M-row benchmark the query is about five times faster.
```

The exact structure is not the rule. The same information could fit naturally
into one paragraph for a smaller change.

## Final check

Before committing, read what you wrote as a maintainer who did not see this
session.

- Does each new or retained comment still tell the reader something after they
  understand what the code does?
- Is a comment merely explaining why an ordinary line is important?
- Does the commented code actually invite a plausible but incorrect
  simplification?
- Does the comment explain the hidden reason that simplification would be wrong?
- For a non-trivial commit, could a maintainer recover why the change was
  necessary?
