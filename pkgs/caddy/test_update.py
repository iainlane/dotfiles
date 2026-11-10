import json
import tempfile
import unittest
from pathlib import Path

from update import discovered_hash, update


class CaddyUpdateTest(unittest.TestCase):
    def test_refresh_preserves_pins_and_normal_update_advances_them(self) -> None:
        for refresh in [False, True]:
            with self.subTest(refresh=refresh):
                self.check_mode(refresh)

    def check_mode(self, refresh: bool) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.json"
            original = {
                "plugins": {"example.invalid/plugin": "v1.0.0"},
                "hashes": {"stable": "old", "unstable": "old"},
            }
            source.write_text(json.dumps(original))
            calls = []

            def discover(module: str) -> str:
                calls.append(module)
                return "v1.1.0"

            def build(channel: str, system: str) -> str:
                calls.append(channel + ":" + system)
                return "new-" + channel

            update(source, "fixture-system", refresh, discover, build)
            self.assertEqual(
                {"source": json.loads(source.read_text()), "calls": calls},
                {
                    "source": {
                        "plugins": {
                            "example.invalid/plugin": "v1.0.0" if refresh else "v1.1.0"
                        },
                        "hashes": {"stable": "new-stable", "unstable": "new-unstable"},
                    },
                    "calls": ([] if refresh else ["example.invalid/plugin"])
                    + ["stable:fixture-system", "unstable:fixture-system"],
                },
            )

    def test_a_failed_channel_restores_all_pins_and_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.json"
            original = '{"plugins":{}, "hashes":{"stable":"old","unstable":"old"}}\n'
            source.write_text(original)

            def build(channel: str, _system: str) -> str:
                if channel == "unstable":
                    raise ValueError("Build failed.")
                return "new"

            with self.assertRaisesRegex(ValueError, "Build failed"):
                update(source, "fixture", True, lambda _: "unused", build)
            self.assertEqual(source.read_text(), original)

    def test_accepts_only_the_target_derivations_hash_mismatch(self) -> None:
        digest = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        log = (
            "error: hash mismatch in fixed-output derivation '/nix/store/fixture.drv':\n specified: old\n got: "
            + digest
        )
        self.assertEqual(discovered_hash(log, "/nix/store/fixture.drv"), digest)
        for output in [
            log.replace("fixture.drv", "other.drv"),
            "error: authentication failed",
            "error: compiler failed",
        ]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                discovered_hash(output, "/nix/store/fixture.drv")


if __name__ == "__main__":
    unittest.main()
