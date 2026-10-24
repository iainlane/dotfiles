import importlib.metadata
import runpy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1)) / "lib/node_modules/rea-agents/bridge/pwntools"


class VersionPolicyTest(unittest.TestCase):
    def test_observed_versions_preserve_format_validation(self):
        versions = {"pwntools": "99.1.0", "pyelftools": "99.2", "unicorn": "99.3.0"}
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "invalid.elf"
            target.write_bytes(b"invalid ELF")
            for filename, inspect, failure in (
                ("layout_impl.py", "inspect_elf", "LayoutFailure"),
                ("recorded_crash_impl.py", "inspect_core", "CoreFailure"),
            ):
                with self.subTest(filename=filename):
                    module = runpy.run_path(str(ROOT / filename))
                    with patch.object(
                        importlib.metadata, "version", side_effect=versions.__getitem__
                    ):
                        self.assertEqual(
                            module["observed_profile"](),
                            "pwntools@99.1.0;pyelftools@99.2;unicorn@99.3.0",
                        )
                        with self.assertRaises(module[failure]) as caught:
                            module[inspect](target, Path(temporary) / "cache")
                        self.assertEqual(caught.exception.reason, "format")


if __name__ == "__main__":
    unittest.main()
