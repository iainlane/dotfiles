import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
import urllib.request
from pathlib import Path


class UpdateError(Exception):
    pass


def versions(config: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for name in ["highcharts", "chartkick", "maplibre-gl"]:
        found = set(re.findall(rf"/js/{name}/(\d+\.\d+\.\d+)/", config))
        if len(found) != 1:
            raise UpdateError(
                f"Expected one {name} version in the packaged renderer configuration."
            )
        result[name] = found.pop()
    return result


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def update(source: Path, config: str, force: bool) -> None:
    current = json.loads(source.read_bytes())
    wanted = versions(config)
    if {
        name: value["version"] for name, value in current.items()
    } == wanted and not force:
        print("LaraPaper web libraries already match the packaged renderer.")
        return

    record: dict[str, dict[str, str]] = {}
    for name, version in wanted.items():
        archive = fetch(f"https://registry.npmjs.org/{name}/-/{name}-{version}.tgz")
        digest = base64.b64encode(hashlib.sha256(archive).digest()).decode()
        record[name] = {"version": version, "hash": "sha256-" + digest}

    with tempfile.NamedTemporaryFile(dir=source.parent, delete=False) as temporary:
        staged = Path(temporary.name)
        temporary.write((json.dumps(record, indent=2) + "\n").encode())
    try:
        os.replace(staged, source)
    finally:
        staged.unlink(missing_ok=True)
    print("Updated LaraPaper web libraries from the packaged renderer.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    arguments = parser.parse_args()
    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True
        ).strip()
        vendor = subprocess.check_output(
            [
                "nix",
                "build",
                f"{root}#packages.aarch64-linux.larapaper.composerVendor",
                "--no-link",
                "--print-out-paths",
            ],
            text=True,
        ).strip()
        config = (
            Path(vendor) / "vendor/bnussbau/trmnl-blade/config/trmnl-blade.php"
        ).read_text()
        update(Path("sources.json"), config, arguments.force)
    except (
        UpdateError,
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        parser.exit(1, f"LaraPaper web library update failed: {error}\n")


if __name__ == "__main__":
    main()
