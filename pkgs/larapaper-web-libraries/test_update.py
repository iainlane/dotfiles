import base64
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import update


class UpdateTests(unittest.TestCase):
    config = "'https://trmnl.com/js/highcharts/12.3.0/highcharts.js' 'https://trmnl.com/js/chartkick/5.0.1/chartkick.min.js' 'https://trmnl.com/js/maplibre-gl/5.24.0/maplibre-gl.js'"

    def test_versions_follow_renderer_configuration(self):
        self.assertEqual(
            update.versions(self.config),
            {"highcharts": "12.3.0", "chartkick": "5.0.1", "maplibre-gl": "5.24.0"},
        )

    def test_incomplete_or_conflicting_configuration_is_rejected(self):
        for config in [
            "",
            self.config + " 'https://trmnl.com/js/highcharts/13.0.0/pattern-fill.js'",
        ]:
            with self.subTest(config=config), self.assertRaises(update.UpdateError):
                update.versions(config)

    def test_refreshes_complete_source_record_and_preserves_it_on_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sources.json"
            original = b"{}\n"
            source.write_bytes(original)
            with patch.object(update, "fetch", return_value=b"archive"):
                update.update(source, self.config, False)
            expected = {
                name: {
                    "version": version,
                    "hash": "sha256-"
                    + base64.b64encode(hashlib.sha256(b"archive").digest()).decode(),
                }
                for name, version in update.versions(self.config).items()
            }
            self.assertEqual(json.loads(source.read_bytes()), expected)
            refreshed = source.read_bytes()
            with (
                patch.object(update, "fetch", side_effect=OSError("download failed")),
                self.assertRaisesRegex(OSError, "download failed"),
            ):
                update.update(source, self.config, True)
            self.assertEqual(source.read_bytes(), refreshed)

    def test_current_versions_skip_downloads(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sources.json"
            record = {
                name: {"version": version, "hash": "existing"}
                for name, version in update.versions(self.config).items()
            }
            original = json.dumps(record).encode()
            source.write_bytes(original)
            with patch.object(update, "fetch") as fetch:
                update.update(source, self.config, False)
            self.assertEqual((source.read_bytes(), fetch.call_count), (original, 0))


if __name__ == "__main__":
    unittest.main()
