import base64
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import update


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.source = Path(self.directory.name) / "source.json"
        self.record = {
            "repository": "owner/model",
            "version": "0.6b-v3",
            "revision": "a" * 40,
            "files": {"weights.onnx": "old weights", "config.json": "old config"},
        }
        self.original = (json.dumps(self.record, indent=2) + "\n").encode()
        self.source.write_bytes(self.original)

    def test_current_revision_is_unchanged(self):
        with patch.object(
            update, "fetch", return_value=json.dumps({"sha": "a" * 40}).encode()
        ) as fetch:
            update.update(self.source, False)
        self.assertEqual(
            (self.source.read_bytes(), fetch.call_count), (self.original, 1)
        )

    def test_new_revision_refreshes_every_file(self):
        revision = "b" * 40
        metadata = [
            {"path": "weights.onnx", "lfs": {"oid": "1" * 64}},
            {"path": "config.json"},
        ]
        with patch.object(
            update,
            "fetch",
            side_effect=[
                json.dumps({"sha": revision}).encode(),
                json.dumps(metadata).encode(),
                b"configuration",
            ],
        ):
            update.update(self.source, False)
        expected = self.record | {
            "revision": revision,
            "files": {
                "weights.onnx": "sha256-"
                + base64.b64encode(bytes.fromhex("1" * 64)).decode(),
                "config.json": "sha256-"
                + base64.b64encode(hashlib.sha256(b"configuration").digest()).decode(),
            },
        }
        self.assertEqual(json.loads(self.source.read_bytes()), expected)

    def test_failed_download_preserves_source(self):
        metadata = [
            {"path": "weights.onnx", "lfs": {"oid": "1" * 64}},
            {"path": "config.json"},
        ]
        with (
            patch.object(
                update,
                "fetch",
                side_effect=[
                    json.dumps({"sha": "b" * 40}).encode(),
                    json.dumps(metadata).encode(),
                    OSError("download failed"),
                ],
            ),
            self.assertRaisesRegex(OSError, "download failed"),
        ):
            update.update(self.source, False)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_force_checks_current_revision_and_rejects_missing_files(self):
        with (
            patch.object(
                update,
                "fetch",
                side_effect=[json.dumps({"sha": "a" * 40}).encode(), b"[]"],
            ),
            self.assertRaisesRegex(update.UpdateError, "weights.onnx"),
        ):
            update.update(self.source, True)
        self.assertEqual(self.source.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
