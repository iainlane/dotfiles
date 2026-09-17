# prose-lint

A [Vale][vale] style and a command-line front end that read prose against the
[Plain technical prose][style] output style. It reads the same three places the
style covers: comments in source files, Markdown documents, and commit messages.
Vale finds the constructions; the command line decides which rules run where,
replies to Claude Code hooks, and records the overrides that a project has
agreed to.

Comments are read as Markdown, so code spans inside them are skipped and the
part-of-speech rules run. For the languages Vale parses, the packaged
configuration maps each to Markdown. For Nix, shell and the other formats with
`#` comments, which Vale cannot parse, `prose-lint check` extracts the comments
itself, one line per source line, and passes the file's path along so that the
code-only rules apply and the report names the file. Vale run directly on those
files, as an editor does, still lints their comments through the packaged Perl
mapping, without the part-of-speech rules.

```console
nix run .#prose-lint -- check README.md
nix run .#prose-lint -- commit-msg .git/COMMIT_EDITMSG
```

Both commands exit 1 when a rule reports at error level and 0 otherwise, so
either can stand in a git hook.

Vale reads several files in one run, and a file that it cannot parse fails that
run. `check` therefore reads a failed batch again one file at a time: the file
that Vale still cannot parse is reported as an error against that file, and
every other file reports its findings as usual.

[vale]: https://vale.sh
[style]: ../../features/ai/output-style/plain-technical-prose.md

## Tiers

`tiers.toml` records, for every rule, the tier it belongs to, the level it runs
at, whether it can be lowered, and the files it applies to.

A **portable** rule belongs to the style itself: arrow chains, abstract
absences, trailing benefit clauses without a mechanism, stock intensifiers,
invented alternatives. These read the same way in anyone's repository, so they
run at their configured level everywhere.

A **house** rule is one writer's local preference: British against American
spelling, `e.g.` and `i.e.`, `please`, exclamation marks. Outside that writer's
own repositories a house rule is capped at warning, so it can report but never
fail a check in a project that has made a different choice.

prose-lint decides whose repository it is from the git remotes. It reads the
owner out of every remote URL, in both the SSH and HTTPS GitHub forms, and
treats the repository as the owner's only when every remote points at an account
listed in `owners`. That list comes from
`$XDG_CONFIG_HOME/prose-lint/config.toml`, or `~/.config/prose-lint/config.toml`
when `XDG_CONFIG_HOME` is unset; `PROSE_LINT_CONFIG` gives the path directly.
Outside a git repository nothing is owned and every house rule runs at warning.

Spelling works the same way. `git grep` counts a few British and American forms
across the tracked files, and the majority decides which of `BritishSpelling`
and `AmericanSpelling` runs; the other stays off. With no prose either way an
owned repository gets British English and any other repository gets neither
rule. `SpellingConsistency` runs regardless: it reports a document that uses
both forms of the same word, whichever variant the project writes.

`licence` and `license` are in the substitution tables because the noun differs
between the two variants. The rule cannot see whether a given occurrence is the
noun or the verb, and British English spells the verb `license`, so a project
that writes about licensing will want `prose-lint allow BritishSpelling`.

## Overrides

A project whose conventions genuinely require a flagged construction lowers the
rule:

```console
prose-lint allow Latin --because "docs/style.md asks for e.g. in tables"
prose-lint disallow Latin
prose-lint overrides
```

`allow` drops the rule to warning, or to `NO` with `--level NO`. It never raises
a rule above the level `tiers.toml` gives it.

An override is refused in two cases. A rule marked `locked` in `tiers.toml`
cannot be lowered at all: `ArrowChain`, `AbstractAbsence` and `ReviewRationale`
describe faults with no legitimate use, so the fix is to change the prose. The
reason must also mention a path that exists in the repository, so every override
points at the file that records the convention.

Overrides live in `<git-common-dir>/info/prose-lint.toml`, which git does not
track, so they stay on the machine that made them. Outside a git repository they
go to `$XDG_STATE_HOME/prose-lint/sessions/<session id>.toml` instead.

## Claude Code hooks

`prose-lint hook post-tool-use` reads a hook payload on standard input and lints
the file an `Edit`, `Write` or `MultiEdit` call has just written. Errors come
back as a `block` decision, warnings as additional context, and a file with
neither produces no output at all.

`prose-lint hook pre-tool-use` reads a `Bash` payload and acts only on a
`git commit` that supplies its message inline, whether through one or more `-m`
options, a heredoc feeding `-F -`, or `-F` with a path. Errors deny the call;
warnings let it through with the findings attached. Every other command produces
no output.

Both hooks exit 0 whatever they find, so a failure to parse a payload never
stops the session.

## Fixtures

Each rule has a directory under `fixtures/` containing a file the rule must
report, a file it must not report, an `expr` filter that selects that rule's
alerts, and the golden Vale output for both files. `fixtures/archive/` contains
sentences taken from this repository's own history, and its golden file records
which rule catches each one. Its `testvalid.md` is the other half of that
record: a sentence that the style rejects and that no mechanical rule detects.

`SpellingConsistency` filters on `.Name startsWith` rather than `.Name ==`,
because for a consistency check Vale appends the offending variant to the alert
name.

`nix build .#checks.<system>.prose-lint-fixtures` runs Vale over every fixture
with the packaged configuration and diffs the result against the golden files.
After changing a rule, regenerate them:

```console
nix build .#prose-lint
./result/share/prose-lint/goldens.bash ./result/share/prose-lint ./fixtures
```

Read the diff before committing it. A golden file that changed in a way you
cannot account for means the rule now reports something you did not intend.
