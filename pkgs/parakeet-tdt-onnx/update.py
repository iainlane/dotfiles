import argparse
import base64
import hashlib
import json
import os
import re
import tempfile
import urllib.request
from pathlib import Path


class UpdateError(Exception):
    pass


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def update(source: Path, force: bool) -> None:
    record = json.loads(source.read_bytes())
    repository = record["repository"]
    revision = json.loads(fetch(f"https://huggingface.co/api/models/{repository}"))[
        "sha"
    ]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise UpdateError("The model repository returned an invalid revision.")
    if revision == record["revision"] and not force:
        print(f"Parakeet is already at {revision}.")
        return

    metadata = json.loads(
        fetch(f"https://huggingface.co/api/models/{repository}/tree/{revision}")
    )
    entries = {entry["path"]: entry for entry in metadata}
    hashes: dict[str, str] = {}
    for name in record["files"]:
        if name not in entries:
            raise UpdateError(f"The model revision has no {name}.")
        entry = entries[name]
        if "lfs" in entry:
            digest = entry["lfs"]["oid"]
            if not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise UpdateError(
                    f"The model revision has an invalid LFS checksum for {name}."
                )
            checksum = bytes.fromhex(digest)
        else:
            checksum = hashlib.sha256(
                fetch(f"https://huggingface.co/{repository}/resolve/{revision}/{name}")
            ).digest()
        hashes[name] = "sha256-" + base64.b64encode(checksum).decode()

    record.update(revision=revision, files=hashes)
    with tempfile.NamedTemporaryFile(dir=source.parent, delete=False) as temporary:
        staged = Path(temporary.name)
        temporary.write((json.dumps(record, indent=2) + "\n").encode())
    try:
        os.replace(staged, source)
    finally:
        staged.unlink(missing_ok=True)
    print(f"Updated Parakeet to {revision}.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    arguments = parser.parse_args()
    try:
        update(Path("source.json"), arguments.force)
    except (UpdateError, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Parakeet update failed: {error}\n")


if __name__ == "__main__":
    main()
