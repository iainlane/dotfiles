import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from collections.abc import Callable
from pathlib import Path


def latest_version(module: str) -> str:
    with urllib.request.urlopen(
        f"https://proxy.golang.org/{module}/@v/list", timeout=60
    ) as response:
        versions = response.read().decode().splitlines()
    releases = [
        version for version in versions if re.fullmatch(r"v\d+\.\d+\.\d+", version)
    ]
    if not releases:
        raise ValueError(f"No stable Go module release found for {module}")
    return max(releases, key=lambda version: tuple(map(int, version[1:].split("."))))


def discovered_hash(log: str, derivation: str) -> str:
    pattern = rf"hash mismatch in fixed-output derivation '{re.escape(derivation)}':\s*specified:\s*\S+\s*got:\s*(sha256-[A-Za-z0-9+/]{{43}}=)"
    match = re.search(pattern, log)
    if match is None:
        raise ValueError(
            f"Could not recompute {derivation}; expected its fixed-output hash mismatch. See diagnostic logs."
        )
    return match[1]


def source_hash(channel: str, system: str) -> str:
    target = f".#legacyPackages.{system}.maintenanceTargets.caddy.{channel}"
    derivation = subprocess.check_output(
        ["nix", "eval", "--raw", target + ".drvPath"], text=True
    ).strip()
    result = subprocess.run(
        ["nix", "build", "--no-link", "--log-format", "raw", target],
        capture_output=True,
        text=True,
        check=False,
    )
    sys.stderr.write(result.stderr)
    if result.returncode == 0:
        raise ValueError(
            "The source unexpectedly matched the fake hash; refusing to reuse a cached source."
        )
    return discovered_hash(result.stderr, derivation)


def write_source(source: Path, contents: bytes) -> None:
    with tempfile.NamedTemporaryFile(dir=source.parent, delete=False) as temporary:
        staged = Path(temporary.name)
        temporary.write(contents)
    try:
        os.replace(staged, source)
    finally:
        staged.unlink(missing_ok=True)


def update(
    source: Path,
    system: str,
    refresh: bool,
    discover: Callable[[str], str] = latest_version,
    build: Callable[[str, str], str] = source_hash,
) -> None:
    original = source.read_bytes()
    record = json.loads(original)
    if not refresh:
        record["plugins"] = {module: discover(module) for module in record["plugins"]}
    try:
        write_source(source, (json.dumps(record, indent=2) + "\n").encode())
        hashes = {channel: build(channel, system) for channel in ["stable", "unstable"]}
        record["hashes"] = hashes
        write_source(source, (json.dumps(record, indent=2) + "\n").encode())
    except (ValueError, OSError, subprocess.CalledProcessError):
        write_source(source, original)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--refresh", action="store_true")
    arguments = parser.parse_args()
    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True
        ).strip()
        system = subprocess.check_output(
            ["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"],
            text=True,
        ).strip()
        os.chdir(root)
        update(Path("pkgs/caddy/source.json"), system, arguments.refresh)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Caddy update failed: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
