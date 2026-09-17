from __future__ import annotations

import re
import tempfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field, replace
from functools import cached_property
from pathlib import Path

from prose_lint.changes import added_lines, every_line
from prose_lint.comments import hash_comments, mirror_pairs
from prose_lint.config import Config, state_home
from prose_lint.configuration import render_configuration
from prose_lint.git import Git
from prose_lint.levels import Level
from prose_lint.overrides import Override, read_overrides, write_overrides
from prose_lint.owners import repository_is_owned
from prose_lint.policy import effective_levels
from prose_lint.relative_clauses import (
    RELATIVE_CLAUSE_RULES,
    without_contained_duplicates,
    without_fronted_adverbials,
    without_mistagged_adverbials,
)
from prose_lint.report import Finding, Report
from prose_lint.rules import HASH_COMMENT_SUFFIXES, RuleCatalogue
from prose_lint.spelling import SpellingVariant, detect_variant
from prose_lint.vale import Vale, ValeFailed, ValeInvocation

_SESSION_ID = re.compile(r"^[A-Za-z0-9_-]+$")


@dataclass
class Runtime:
    """Everything one prose-lint run needs, with git and vale injected."""

    share: Path
    catalogue: RuleCatalogue
    config: Config
    git: Git
    vale: Vale
    cwd: Path
    session_id: str = "default"
    _scratch: tempfile.TemporaryDirectory[str] | None = field(
        default=None, init=False, repr=False
    )

    @property
    def root(self) -> Path:
        return self.git.root() or self.cwd

    @cached_property
    def owned(self) -> bool:
        return repository_is_owned(self.git.remote_urls(), self.config.owners)

    @cached_property
    def variant(self) -> SpellingVariant:
        return detect_variant(self.git, owned=self.owned)

    @property
    def overrides_path(self) -> Path:
        common = self.git.common_directory()
        if common is not None:
            return common / "info" / "prose-lint.toml"

        session = self.session_id if _SESSION_ID.match(self.session_id) else "default"

        return state_home() / "prose-lint" / "sessions" / f"{session}.toml"

    def overrides(self) -> tuple[Override, ...]:
        return read_overrides(self.overrides_path, self.catalogue)

    def record_override(self, override: Override) -> None:
        kept = [
            existing for existing in self.overrides() if existing.rule != override.rule
        ]
        write_overrides(self.overrides_path, [*kept, override])

    def drop_override(self, name: str) -> bool:
        existing = self.overrides()
        kept = [override for override in existing if override.rule != name]

        if len(kept) == len(existing):
            return False

        write_overrides(self.overrides_path, kept)

        return True

    def levels(self) -> dict[str, Level]:
        return effective_levels(
            self.catalogue,
            owned=self.owned,
            variant=self.variant,
            overrides={override.rule: override.level for override in self.overrides()},
        )

    def configuration(self) -> Path:
        if self._scratch is None:
            self._scratch = tempfile.TemporaryDirectory(prefix="prose-lint-")

        destination = Path(self._scratch.name) / "vale.ini"
        destination.write_text(
            render_configuration(
                self.base_configuration(), self.catalogue, self.levels()
            )
        )

        return destination

    def base_configuration(self) -> str:
        packaged = self.share / "vale.ini"
        if packaged.is_file():
            return packaged.read_text()

        template = (self.share / "vale.ini.in").read_text()

        return template.replace("@stylesPath@", str(self.share / "styles"))

    def lint_paths(self, paths: tuple[Path, ...]) -> Report:
        direct = tuple(
            p for p in paths if p.suffix.lower() not in HASH_COMMENT_SUFFIXES
        )
        extracted = tuple(p for p in paths if p.suffix.lower() in HASH_COMMENT_SUFFIXES)
        comments: dict[Path, str] = {}
        unreadable: list[Finding] = []

        for path in extracted:
            try:
                comments[path] = hash_comments(path.read_text())
            except (OSError, UnicodeDecodeError) as error:
                unreadable.append(_failure_finding(path, error))

        findings: list[Finding] = []

        if direct:
            findings.extend(self._lint_directly(direct))

        if comments:
            findings.extend(self._lint_comments(comments))

        findings.extend(unreadable)

        return Report(_refined(tuple(findings), _texts(findings, comments)))

    def lint_added_lines(self) -> Report:
        """The findings on the lines the working tree has added to HEAD.

        An untracked file counts as added in full. Outside a git repository
        the report is empty, because there is no HEAD to compare the working
        tree with.
        """
        root = self.git.root()
        if root is None:
            return Report(())

        added = {
            root / relative: added_lines(self.git.diff_against_head(relative))
            for relative in self.git.changed_paths()
        }
        added.update(
            {
                root / relative: every_line(root / relative)
                for relative in self.git.untracked_paths()
            }
        )

        paths = tuple(
            path for path in added if path.is_file() and self.catalogue.lintable(path)
        )

        if not paths:
            return Report(())

        report = self.lint_paths(paths)

        return Report(
            tuple(
                finding
                for finding in report.findings
                if finding.line in added.get(Path(finding.path), frozenset())
            )
        )

    def lint_staged_lines(self, paths: tuple[Path, ...]) -> Report:
        """The findings on the lines that the index adds to HEAD, in `paths`.

        A file that is new in the index has every line in its staged diff.
        Outside a git repository there is no HEAD to compare the index with,
        and the report is empty.
        """
        if self.git.root() is None:
            return Report(())

        staged = {path: added_lines(self.git.diff_staged(path)) for path in paths}
        changed = tuple(path for path, lines in staged.items() if lines)

        if not changed:
            return Report(())

        report = self.lint_paths(changed)

        return Report(
            tuple(
                finding
                for finding in report.findings
                if finding.line in staged.get(Path(finding.path), frozenset())
            )
        )

    def _lint_directly(self, paths: tuple[Path, ...]) -> tuple[Finding, ...]:
        """The findings in the files Vale reads for itself.

        Vale reads the whole batch in one run, so a single file that it
        cannot parse fails that run and the findings for every other file
        are lost with it. A failed batch is therefore read again one file
        at a time: every file that Vale can parse reports its findings, and
        every file that still fails becomes an error against that file.
        """
        if len(paths) > 1:
            try:
                return self.vale.lint(
                    ValeInvocation(config=self.configuration(), paths=paths)
                )
            except ValeFailed:
                pass

        findings: list[Finding] = []

        for path in paths:
            try:
                findings.extend(
                    self.vale.lint(
                        ValeInvocation(config=self.configuration(), paths=(path,))
                    )
                )
            except ValeFailed as failure:
                findings.append(_failure_finding(path, failure))

        return tuple(findings)

    def _lint_comments(self, comments: Mapping[Path, str]) -> tuple[Finding, ...]:
        """The findings in the extracted `#` comments of several files.

        Each file's comments are written to a file of their own in a scratch
        directory, and one Vale process reads them all. Vale keeps a document
        per file, so a rule that reads a whole document, such as the spelling
        consistency check, reports the same as it does when the source file is
        read on its own.

        `--ext` makes Vale parse each mirror file as Markdown, which the
        part-of-speech rules need. The mirror's own name still selects the
        rules for code. `hash_comments` writes one line per source line, so an
        alert's line is its line in the source file.
        """
        with tempfile.TemporaryDirectory(prefix="prose-lint-comments-") as scratch:
            pairs = mirror_pairs(Path(scratch), tuple(comments))

            for mirror, path in pairs:
                mirror.write_text(comments[path])

            return self._lint_mirrors(dict(pairs))

    def _lint_mirrors(self, sources: Mapping[Path, Path]) -> tuple[Finding, ...]:
        """The findings in a set of mirror files, reported against their sources.

        As with a batch of files that Vale reads for itself, one file that
        Vale cannot parse fails the whole run, so a failed batch is read again
        one file at a time.
        """
        mirrors = tuple(sources)

        if len(mirrors) > 1:
            try:
                alerts = self.vale.lint(self._comment_invocation(mirrors))
            except ValeFailed:
                pass
            else:
                return tuple(_against_source(sources, alert) for alert in alerts)

        findings: list[Finding] = []

        for mirror in mirrors:
            try:
                findings.extend(
                    _against_source(sources, alert)
                    for alert in self.vale.lint(self._comment_invocation((mirror,)))
                )
            except ValeFailed as failure:
                findings.append(_failure_finding(sources[mirror], failure))

        return tuple(findings)

    def _comment_invocation(self, mirrors: tuple[Path, ...]) -> ValeInvocation:
        return ValeInvocation(
            config=self.configuration(), paths=mirrors, extension=".md"
        )

    def lint_commit_message(self, text: str, display_path: str) -> Report:
        findings = self.vale.lint(
            ValeInvocation(
                config=self.configuration(),
                stdin_text=text,
                extension=".txt",
                display_path=display_path,
            )
        )

        return Report(_refined(findings, {display_path: text}))


def _refined(
    findings: tuple[Finding, ...], texts: Mapping[str, str]
) -> tuple[Finding, ...]:
    """The findings with the three relative-clause corrections applied."""
    return without_contained_duplicates(
        without_mistagged_adverbials(without_fronted_adverbials(findings, texts))
    )


def _texts(findings: Sequence[Finding], comments: Mapping[Path, str]) -> dict[str, str]:
    """The text of every file that a relative-clause rule reported on.

    Both corrections read the sentence of the alert. For a file whose comments
    were extracted, that sentence is in the extracted text, because the
    alert's line is a line of it.
    """
    reported = {
        Path(finding.path)
        for finding in findings
        if finding.rule in RELATIVE_CLAUSE_RULES
    }

    return {
        str(path): comments[path] if path in comments else _source_text(path)
        for path in reported
    }


def _source_text(path: Path) -> str:
    """A file's text, empty when it cannot be decoded.

    prose-lint hands these paths to Vale without opening them, so nothing has
    decoded the file before this point, and Vale tolerates bytes that
    `read_text` raises on. The corrections then skip that file and its alerts
    are reported as Vale gave them.
    """
    try:
        return path.read_text()
    except (OSError, UnicodeDecodeError):
        return ""


def _against_source(sources: Mapping[Path, Path], finding: Finding) -> Finding:
    """One alert on a mirror file, reported against its source file."""
    source = sources.get(Path(finding.path))

    return finding if source is None else replace(finding, path=str(source))


def _failure_finding(path: Path, failure: Exception) -> Finding:
    """A file that prose-lint could not lint, reported as an error against it."""
    return Finding(
        path=str(path),
        line=1,
        column=1,
        rule="prose-lint",
        message=str(failure),
        severity=Level.error,
    )
