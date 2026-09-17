from __future__ import annotations

import re
from collections.abc import Mapping, Sequence

from prose_lint.report import Finding

# The rules that read a noun phrase for an object-relative clause. They match
# the same shapes, so the same two corrections apply to all of them.
RELATIVE_CLAUSE_RULES = frozenset(
    {
        "Prose.ZeroRelative",
        "Prose.ZeroRelativeBare",
        "Prose.ZeroRelativeNamed",
        "Prose.ZeroRelativePronoun",
        "Prose.ZeroRelativeShort",
    }
)

_PREPOSITION = (
    r"(?:In|On|At|For|With|From|By|Under|Within|Outside|Inside|During|After"
    r"|Before|Without|Against|Across|Per|Between|Through|Among|Beyond|Since"
    r"|Until|Above|Below|Near|Around|Over)\b"
)

# A preposition that opens the sentence, with no sentence boundary between it
# and the match.
_FRONTED = re.compile(rf"(?:^|(?<=[.!?]) ){_PREPOSITION}[^.!?]*$")
_OPENS_A_PHRASE = re.compile(_PREPOSITION)

# Vale reports a match as it appears in the source, and a clause may wrap over
# two comment lines. The paragraph is searched with its lines joined by
# spaces, so the match is looked up by its first line, cut to this many
# characters.
_LOOKUP = 40


def without_fronted_adverbials(
    findings: Sequence[Finding], texts: Mapping[str, str]
) -> tuple[Finding, ...]:
    """Every finding but a relative-clause alert on a fronted adverbial.

    "Outside a git repository the hook has" tags as a noun, a determiner, a
    noun and a verb, which is the shape that these rules match. The
    preposition that opens the sentence rules the reading out: the noun before
    the determiner belongs to the adverbial phrase and is not the head of a
    clause.
    """
    return tuple(
        finding
        for finding in findings
        if finding.rule not in RELATIVE_CLAUSE_RULES
        or not _fronted(texts.get(finding.path, ""), finding)
    )


def without_contained_duplicates(findings: Sequence[Finding]) -> tuple[Finding, ...]:
    """Every finding but a relative-clause alert inside another one on its line.

    Two rules read the same clause at different lengths, so the shorter match
    repeats what the longer one already reports.
    """
    by_line: dict[tuple[str, int], list[int]] = {}

    for index, finding in enumerate(findings):
        if finding.rule in RELATIVE_CLAUSE_RULES and finding.match:
            by_line.setdefault((finding.path, finding.line), []).append(index)

    dropped: set[int] = set()

    for indices in by_line.values():
        kept: list[str] = []

        for index in sorted(indices, key=lambda index: -len(findings[index].match)):
            match = findings[index].match

            if any(match in longer for longer in kept):
                dropped.add(index)
                continue

            kept.append(match)

    return tuple(
        finding for index, finding in enumerate(findings) if index not in dropped
    )


def _fronted(text: str, finding: Finding) -> bool:
    """Whether a preposition opens the sentence that the match belongs to."""
    if not finding.match:
        return False

    flow = _paragraph(text.splitlines(), finding.line)
    index = flow.find(finding.match.splitlines()[0][:_LOOKUP])
    head = flow[:index].strip() if index >= 0 else ""

    if not head:
        return _OPENS_A_PHRASE.match(finding.match) is not None

    return _FRONTED.search(head) is not None


def _paragraph(lines: Sequence[str], line: int) -> str:
    """The paragraph up to and including `line`, with its lines joined."""
    if not 1 <= line <= len(lines):
        return ""

    start = line - 1

    while start > 0 and lines[start - 1].strip():
        start -= 1

    return " ".join(lines[start:line])
