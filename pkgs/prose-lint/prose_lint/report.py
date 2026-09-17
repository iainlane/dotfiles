from __future__ import annotations

import json
from dataclasses import asdict, dataclass

from prose_lint.levels import Level

# A hook string longer than 10,000 characters is written to a file and the
# model receives only a preview, so a long list is cut before that point.
LIMIT = 25

ADVICE = (
    "Where this project's conventions require otherwise, lower a rule with "
    '`prose-lint allow <Rule> --because "<reason pointing at a file in the '
    'repository>"`. A locked rule cannot be lowered.'
)


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    column: int
    rule: str
    message: str
    severity: Level
    match: str = ""

    def render(self) -> str:
        return f"{self.path}:{self.line}:{self.column} {self.rule}: {self.message}"


@dataclass(frozen=True)
class Report:
    findings: tuple[Finding, ...]

    @property
    def errors(self) -> tuple[Finding, ...]:
        return tuple(
            finding for finding in self.findings if finding.severity is Level.error
        )

    @property
    def warnings(self) -> tuple[Finding, ...]:
        return tuple(
            finding for finding in self.findings if finding.severity is not Level.error
        )

    def error_text(self) -> str:
        return "\n".join(["errors", *_capped(self.errors), "", ADVICE])

    def warning_text(self) -> str:
        return "\n".join(["warnings", *_capped(self.warnings)])

    def render_lines(self) -> str:
        return "\n".join(finding.render() for finding in self.findings)

    def render_json(self) -> str:
        return json.dumps(
            [
                {**asdict(finding), "severity": finding.severity.value}
                for finding in self.findings
            ],
            indent=2,
        )


def _capped(findings: tuple[Finding, ...]) -> list[str]:
    lines = [finding.render() for finding in findings[:LIMIT]]
    remaining = len(findings) - LIMIT

    if remaining > 0:
        lines.append(f"and {remaining} more")

    return lines
