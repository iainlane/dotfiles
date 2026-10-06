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


def version(config: str, library: str) -> str:
    found = set(re.findall(rf"/js/{re.escape(library)}/(\d+\.\d+\.\d+)/", config))
    if len(found) != 1:
        raise UpdateError(
            f"Expected one {library} version in the packaged renderer configuration."
        )
    return found.pop()


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def update(source: Path, config: str, library: str, force: bool) -> None:
    current = json.loads(source.read_bytes())
    wanted = version(config, library)
    if current.get("version") == wanted and not force:
        print(f"{library} already matches the packaged renderer.")
        return

    archive = fetch(f"https://registry.npmjs.org/{library}/-/{library}-{wanted}.tgz")
    digest = base64.b64encode(hashlib.sha256(archive).digest()).decode()
    record = {"version": wanted, "hash": "sha256-" + digest}

    with tempfile.NamedTemporaryFile(dir=source.parent, delete=False) as temporary:
        staged = Path(temporary.name)
        temporary.write((json.dumps(record, indent=2) + "\n").encode())
    try:
        os.replace(staged, source)
    finally:
        staged.unlink(missing_ok=True)
    print(f"Updated {library} to {wanted} from the packaged renderer.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("library")
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
        update(Path("source.json"), config, arguments.library, arguments.force)
    except (
        UpdateError,
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        parser.exit(1, f"{arguments.library} update failed: {error}\n")


if __name__ == "__main__":
    main()
