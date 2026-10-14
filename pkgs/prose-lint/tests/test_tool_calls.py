from pathlib import Path

import pytest

from prose_lint.tool_calls import edited_paths

CWD = Path("/repository")

PATCH = """\
*** Begin Patch
*** Add File: docs/new.md
+A new file.
*** Update File: README.md
@@
-Old.
+New.
*** Update File: notes/old.md
*** Move to: notes/renamed.md
@@
-Old.
+New.
*** Delete File: gone.md
*** Update File: /elsewhere/absolute.md
@@
-Old.
+New.
*** End Patch
"""


@pytest.mark.parametrize(
    ("tool_name", "tool_input", "expected"),
    [
        ("Edit", {"file_path": "/repository/a.md"}, (Path("/repository/a.md"),)),
        ("Write", {"file_path": "b.md"}, (Path("/repository/b.md"),)),
        ("MultiEdit", {"file_path": "/repository/c.md"}, (Path("/repository/c.md"),)),
        (
            "apply_patch",
            {"command": PATCH},
            (
                Path("/repository/docs/new.md"),
                Path("/repository/README.md"),
                Path("/repository/notes/renamed.md"),
                Path("/elsewhere/absolute.md"),
            ),
        ),
        ("Edit", {"file_path": 3}, ()),
        ("apply_patch", {"command": ["not", "text"]}, ()),
        ("Bash", {"command": "ls"}, ()),
        ("Read", {"file_path": "/repository/a.md"}, ()),
    ],
)
def test_the_edited_paths_are_read_from_each_edit_tool(
    tool_name: str, tool_input: dict[str, object], expected: tuple[Path, ...]
) -> None:
    assert edited_paths(tool_name, tool_input, CWD) == expected
