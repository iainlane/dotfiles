import errno
import os
import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest

from claude_prompt_conformance.storage import replace_private_file


@pytest.mark.parametrize(
    ("operation", "cleanup_fails"),
    [("fdopen", False), ("fsync", False), ("fdopen", True)],
)
def test_replace_private_file_releases_resources_after_failure(
    tmp_path: Path, operation: str, cleanup_fails: bool
) -> None:
    destination = tmp_path / "credentials"
    destination.write_bytes(b"original")
    descriptor, name = tempfile.mkstemp(dir=tmp_path)
    failure = OSError(errno.EIO, "injected write failure")
    descriptor_closed = False
    close = os.close

    def release(open_descriptor: int) -> None:
        close(open_descriptor)
        if cleanup_fails:
            raise OSError(errno.EIO, "injected cleanup failure")

    try:
        with (
            patch("tempfile.mkstemp", return_value=(descriptor, name)),
            patch(f"os.{operation}", side_effect=failure),
            patch("os.close", side_effect=release),
            pytest.raises(OSError) as raised,
        ):
            replace_private_file(destination, b"replacement")

        try:
            os.fstat(descriptor)
        except OSError as error:
            descriptor_closed = error.errno == errno.EBADF

        actual = (
            raised.value is failure,
            descriptor_closed,
            {path.name: path.read_bytes() for path in tmp_path.iterdir()},
        )
    finally:
        if not descriptor_closed:
            os.close(descriptor)

    assert actual == (True, True, {"credentials": b"original"})
