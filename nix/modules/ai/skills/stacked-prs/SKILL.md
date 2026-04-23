---
name: stacked-prs
description: >-
  Take a series of commits and create one PR per commit, with each depending on
  the previous, to create a chain.

allowed-tools: Bash(gh pr create --draft *) Bash(gh pr edit *) Bash(gh pr view *) Bash(git add *) Bash(git checkout *) Bash(git commit *) Bash(git fetch *) Bash(git log *) Bash(git push *) Bash(git rebase *) Bash(git status *) Grep Read
argument-hint: "[--prefix=prefix] [--rebase] <from=branch point> <to=head>"
---

# `stacked-prs`

Make a series of stacked PRs, one commit per PR.

## How to do it

1. Figure out which commits we're working with by inspecting the git log.
2. The commits are to be serialised into a series of PRs, one per commit, each
   depending on the previous. We need to make a branch for each. Unless the user
   passed their own branch prefix, invoke a Haiku subagent, pass it the commit
   range, and have it generate a short branch prefix.
3. Now stop and tell the user what we're going to do. Branch name, commit, PR
   title & description, PR base branch. Break it down per branch. They may
   iterate or modify.
4. Once approved, create the branches, push them, and create the PRs in draft
   mode. Use the actual PR titles as plain text in the stacked PR list within
   each description, since we don't have PR numbers yet.
5. Go back and replace each plain-text title with the actual `#N` reference, now
   that we have all the PR numbers.
6. Show the user a list of all the PRs we created, with numbers, titles and
   links. Ask them if they want to undraft.
7. If they do, undraft all of them and then confirm. You're done.

### PR description

Each PR's description should be like this:

```markdown
## Stacked

This PR is part of a _stack_:

- <title of PR 1>
- ...
  - <title of this PR> ← _you are here_
- ...

## Description

<The commit body, but unwrapped.>
```

## Rebase

GitHub usually breaks when a base branch for one PR is merged. CI will need to
re-run and the UI may falsely report conflicts. We can fix this by rebasing.

If the user supplies the `--rebase` flag, then we can do the following process:

1. Verify that we're on one of the branches for a PR stack which was previously
   created. Use `gh pr view` to work this out.
2. Verify that each PR's base branch was transitively updated after the previous
   one was merged. Fix any that weren't.
3. Find the last branch in the stack and switch to it, so that `--update-refs`
   covers the entire stack.
4. Fetch the ultimate base branch, commonly `main` (but check).
5. Rebase with `--update-refs` so that each branch is updated.
6. `git push --force-with-lease <all the branches>`.
