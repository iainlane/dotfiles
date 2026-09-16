from __future__ import annotations

import re
import tempfile
from dataclasses import dataclass, field
from functools import cached_property
from pathlib import Path

from prose_lint.comments import hash_comments
from prose_lint.config import Config, state_home
from prose_lint.configuration import render_configuration
from prose_lint.git import Git
from prose_lint.levels import Level
from prose_lint.overrides import Override, read_overrides, write_overrides
from prose_lint.owners import repository_is_owned
from prose_lint.policy import effective_levels
from prose_lint.report import Finding, Report
from prose_lint.rules import HASH_COMMENT_SUFFIXES, RuleCatalogue
from prose_lint.spelling import SpellingVariant, detect_variant
from prose_lint.vale import Vale, ValeInvocation

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
        findings: list[Finding] = []

        if direct:
            findings.extend(
                self.vale.lint(
                    ValeInvocation(config=self.configuration(), paths=direct)
                )
            )

        for path in extracted:
            findings.extend(self._lint_comments(path))

        return Report(tuple(findings))

    def _lint_comments(self, path: Path) -> tuple[Finding, ...]:
        """The findings in a file's `#` comments, read as Markdown.

        The path is passed to Vale as a hint so that the configuration
        sections for code apply and the report names the file.
        """
        return self.vale.lint(
            ValeInvocation(
                config=self.configuration(),
                stdin_text=hash_comments(path.read_text()),
                extension=".md",
                path_hint=str(path),
            )
        )

    def lint_commit_message(self, text: str, display_path: str) -> Report:
        return Report(
            self.vale.lint(
                ValeInvocation(
                    config=self.configuration(),
                    stdin_text=text,
                    extension=".txt",
                    display_path=display_path,
                )
            )
        )
