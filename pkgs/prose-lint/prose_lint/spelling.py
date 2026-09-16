from __future__ import annotations

from collections.abc import Sequence
from enum import Enum
from typing import Protocol


class SpellingVariant(Enum):
    british = "british"
    american = "american"
    undecided = "undecided"


# Counting every substitution pair over a whole repository is slow, so a few
# pairs decide the variant. Each pair is a word that ordinary technical prose
# uses in both variants. The licence pair is left out: British English spells
# the verb the American way, and package metadata is full of the word.
#
# The patterns are POSIX extended regular expressions with no word-boundary
# escape, because `git grep -E` does not accept one. The counter matches whole
# words instead.
_BRITISH = (
    r"(colour|colours|behaviour|behaviours|centre|centres|favourite|favourites"
    r"|organis(e|es|ed|ing|ation|ations)|initialis(e|es|ed|ing|ation|ations)"
    r"|recognis(e|es|ed|ing)|analys(e|es|ed|ing))"
)
_AMERICAN = (
    r"(color|colors|behavior|behaviors|center|centers|favorite|favorites"
    r"|organiz(e|es|ed|ing|ation|ations)|initializ(e|es|ed|ing|ation|ations)"
    r"|recogniz(e|es|ed|ing)|analyz(e|es|ed|ing))"
)

# Several of these words are also identifiers. The American spellings of
# colour, centre and initialise are ordinary names in stylesheets, terminal
# code, layout code and library APIs, and over a whole repository they
# outnumber the prose by enough to decide the vote on their own. Only files
# that are prose throughout are counted.
_PROSE_FILES = ("*.md", "*.markdown", "*.txt", "*.rst", "*.adoc")


class MatchCounter(Protocol):
    def count_matches(self, pattern: str, pathspec: Sequence[str] = ()) -> int: ...


def detect_variant(counter: MatchCounter, *, owned: bool) -> SpellingVariant:
    """Choose British or American spelling by majority in the tracked prose.

    With no prose either way, an owned repository gets British English and an
    external one gets neither rule, so prose-lint never imposes a variant on a
    project that has not chosen one.
    """
    british = counter.count_matches(_BRITISH, _PROSE_FILES)
    american = counter.count_matches(_AMERICAN, _PROSE_FILES)

    if british > american:
        return SpellingVariant.british

    if american > british:
        return SpellingVariant.american

    if owned:
        return SpellingVariant.british

    return SpellingVariant.undecided
