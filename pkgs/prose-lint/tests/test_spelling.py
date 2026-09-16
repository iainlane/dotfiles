from collections.abc import Sequence
from dataclasses import dataclass, field

import pytest

from prose_lint.spelling import _AMERICAN, _BRITISH, SpellingVariant, detect_variant


@dataclass
class FakeCounter:
    british: int = 0
    american: int = 0
    pathspecs: list[tuple[str, ...]] = field(default_factory=list)

    def count_matches(self, pattern: str, pathspec: Sequence[str] = ()) -> int:
        self.pathspecs.append(tuple(pathspec))

        if pattern == _BRITISH:
            return self.british

        if pattern == _AMERICAN:
            return self.american

        raise AssertionError(f"unexpected pattern {pattern!r}")


@pytest.mark.parametrize(
    ("british", "american", "owned", "expected"),
    [
        (12, 3, True, SpellingVariant.british),
        (3, 12, True, SpellingVariant.american),
        (12, 3, False, SpellingVariant.british),
        (3, 12, False, SpellingVariant.american),
        (0, 0, True, SpellingVariant.british),
        (0, 0, False, SpellingVariant.undecided),
        (5, 5, True, SpellingVariant.british),
        (5, 5, False, SpellingVariant.undecided),
    ],
)
def test_the_majority_of_the_tracked_prose_chooses_the_variant(
    british: int, american: int, owned: bool, expected: SpellingVariant
) -> None:
    counter = FakeCounter(british=british, american=american)

    assert detect_variant(counter, owned=owned) is expected


def test_only_prose_files_are_counted() -> None:
    """Several of the words are identifiers, and code would outvote the prose."""
    counter = FakeCounter()

    detect_variant(counter, owned=True)

    assert counter.pathspecs == [
        ("*.md", "*.markdown", "*.txt", "*.rst", "*.adoc"),
        ("*.md", "*.markdown", "*.txt", "*.rst", "*.adoc"),
    ]
