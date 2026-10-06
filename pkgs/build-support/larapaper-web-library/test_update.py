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

    def test_version_follows_renderer_configuration(self):
        for library, version in [
            ("highcharts", "12.3.0"),
            ("chartkick", "5.0.1"),
            ("maplibre-gl", "5.24.0"),
        ]:
            with self.subTest(library=library):
                self.assertEqual(update.version(self.config, library), version)

    def test_missing_or_conflicting_version_is_rejected(self):
        for config in [
            "",
            self.config + " 'https://trmnl.com/js/highcharts/13.0.0/pattern-fill.js'",
        ]:
            with self.subTest(config=config), self.assertRaises(update.UpdateError):
                update.version(config, "highcharts")

    def test_refreshes_source_record_and_preserves_it_on_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.json"
            source.write_bytes(b"{}\n")
            with patch.object(update, "fetch", return_value=b"archive") as fetch:
                update.update(source, self.config, "chartkick", False)
            expected = {
                "version": "5.0.1",
                "hash": "sha256-"
                + base64.b64encode(hashlib.sha256(b"archive").digest()).decode(),
            }
            self.assertEqual(
                (json.loads(source.read_bytes()), fetch.call_args.args),
                (
                    expected,
                    ("https://registry.npmjs.org/chartkick/-/chartkick-5.0.1.tgz",),
                ),
            )
            refreshed = source.read_bytes()
            with (
                patch.object(update, "fetch", side_effect=OSError("download failed")),
                self.assertRaisesRegex(OSError, "download failed"),
            ):
                update.update(source, self.config, "chartkick", True)
            self.assertEqual(source.read_bytes(), refreshed)

    def test_current_version_skips_download(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.json"
            original = json.dumps({"version": "24.0.0", "hash": "existing"}).encode()
            source.write_bytes(original)
            config = self.config.replace("5.24.0", "24.0.0")
            with patch.object(update, "fetch") as fetch:
                update.update(source, config, "maplibre-gl", False)
            self.assertEqual((source.read_bytes(), fetch.call_count), (original, 0))


if __name__ == "__main__":
    unittest.main()
