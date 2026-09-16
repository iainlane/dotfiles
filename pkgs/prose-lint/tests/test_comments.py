import pytest

from prose_lint.comments import hash_comments


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("# A comment.\nx = 1\n", "A comment.\n\n"),
        ("x = 1\n  # Indented comment.\n", "\nIndented comment.\n"),
        ("#!/usr/bin/env bash\n# Real comment.\n", "\nReal comment.\n"),
        ("#No space.\n", "No space.\n"),
        ("# First.\n# Second.\n\n# Third.\n", "First.\nSecond.\n\nThird.\n"),
    ],
)
def test_comments_keep_their_line_numbers(source: str, expected: str) -> None:
    assert hash_comments(source) == expected
