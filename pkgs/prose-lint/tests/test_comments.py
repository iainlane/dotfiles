from pathlib import Path

import pytest

from prose_lint.comments import hash_comments, mirror_pairs


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


@pytest.mark.parametrize(
    ("paths", "expected"),
    [
        (
            (Path("one.nix"),),
            ((Path("/scratch/0.nix"), Path("one.nix")),),
        ),
        (
            tuple(Path(f"f{index}.sh") for index in range(11)),
            tuple(
                (Path(f"/scratch/{index:02d}.nix"), Path(f"f{index}.sh"))
                for index in range(11)
            ),
        ),
    ],
)
def test_each_file_gets_a_mirror_whose_name_keeps_the_order(
    paths: tuple[Path, ...], expected: tuple[tuple[Path, Path], ...]
) -> None:
    assert mirror_pairs(Path("/scratch"), paths) == expected
