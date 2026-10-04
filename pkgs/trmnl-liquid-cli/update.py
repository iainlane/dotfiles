import argparse
import hashlib
import io
import json
import os
import re
import struct
import subprocess
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


class UpdateError(Exception):
    pass


def fetch(url: str, headers: dict[str, str] | None = None) -> bytes:
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def json_object(data: bytes) -> dict[str, object]:
    value = json.loads(data)
    if not isinstance(value, dict):
        raise UpdateError("Expected a JSON object from the release API.")
    return value


def latest_version(tags: list[str]) -> str:
    versions = [tag for tag in tags if re.fullmatch(r"\d+\.\d+\.\d+", tag)]
    if not versions:
        raise UpdateError("No stable Liquid CLI container tags found.")
    return max(versions, key=lambda tag: tuple(int(part) for part in tag.split(".")))


def embedded_filesystem(binary: bytes) -> bytes:
    magic = b"DWARFS\x02\x05"
    start = binary.find(magic)
    if start < 0:
        raise UpdateError("No supported DwarFS 2.5 image found in the Liquid CLI.")
    position = start
    number = 0
    while binary[position : position + len(magic)] == magic:
        if position + 64 > len(binary):
            raise UpdateError("The embedded filesystem header is truncated.")
        section_number = struct.unpack_from("<I", binary, position + 48)[0]
        if section_number != number:
            raise UpdateError("Unexpected embedded filesystem section sequence.")
        length = struct.unpack_from("<Q", binary, position + 56)[0]
        end = position + 64 + length
        if end > len(binary):
            raise UpdateError("The embedded filesystem payload is truncated.")
        position = end
        number += 1
    # The filesystem ends inside an ELF segment. Passing the rest of that
    # segment to DwarFS makes the reader interpret ELF bytes as sections.
    return binary[start:position]


def publish(package: Path, files: dict[str, bytes]) -> None:
    originals = {name: (package / name).read_bytes() for name in files}
    with tempfile.TemporaryDirectory(dir=package) as directory:
        staged = Path(directory)
        for name, content in files.items():
            (staged / name).write_bytes(content)
        try:
            for name in files:
                os.replace(staged / name, package / name)
        except OSError:
            for name, content in originals.items():
                (package / name).write_bytes(content)
            raise


@dataclass(frozen=True)
class Release:
    version: str
    manifest_digest: str
    layers: list[str]


class Registry:
    repository = "bnussbau/trmnl-liquid-cli"

    def __init__(self) -> None:
        token = json_object(
            fetch(
                "https://auth.docker.io/token?service=registry.docker.io"
                f"&scope=repository:{self.repository}:pull"
            )
        )["token"]
        if not isinstance(token, str):
            raise UpdateError("The registry did not return a pull token.")
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json",
        }

    def latest(self, platform: str) -> Release:
        url: str | None = (
            f"https://hub.docker.com/v2/repositories/{self.repository}/tags?page_size=100"
        )
        tags: list[str] = []
        while url:
            page = json_object(fetch(url))
            results = page["results"]
            if not isinstance(results, list):
                raise UpdateError("The registry tag response has no results list.")
            for result in results:
                if isinstance(result, dict) and isinstance(result.get("name"), str):
                    tags.append(result["name"])
            next_page = page.get("next")
            url = next_page if isinstance(next_page, str) else None
        version = latest_version(tags)
        tag = json_object(
            fetch(
                f"https://hub.docker.com/v2/repositories/{self.repository}/tags/{version}"
            )
        )
        images = tag["images"]
        if not isinstance(images, list):
            raise UpdateError("The registry tag has no images list.")
        os_name, architecture = platform.split("/")
        digests = [
            image["digest"]
            for image in images
            if isinstance(image, dict)
            and image.get("os") == os_name
            and image.get("architecture") == architecture
            and isinstance(image.get("digest"), str)
        ]
        if len(digests) != 1:
            raise UpdateError(f"Expected one Liquid CLI image for {platform}.")
        digest = digests[0]
        manifest = json_object(self.blob(f"manifests/{digest}", digest))
        layers = manifest["layers"]
        if not isinstance(layers, list):
            raise UpdateError("The image manifest has no layers list.")
        layer_digests: list[str] = []
        for layer in layers:
            if not isinstance(layer, dict) or not isinstance(layer.get("digest"), str):
                raise UpdateError("An image layer has no digest.")
            layer_digests.append(layer["digest"])
        return Release(version, digest, layer_digests)

    def blob(self, path: str, digest: str) -> bytes:
        data = fetch(
            f"https://registry-1.docker.io/v2/{self.repository}/{path}", self.headers
        )
        if f"sha256:{hashlib.sha256(data).hexdigest()}" != digest:
            raise UpdateError(
                f"The registry returned bytes that do not match {digest}."
            )
        return data

    def binary(self, release: Release) -> tuple[bytes, str]:
        target = PurePosixPath("usr/local/bin/trmnl-liquid-cli")
        whiteouts = {
            str(path.parent / f".wh.{path.name}")
            for path in [target, *target.parents]
            if path.name
        } | {str(parent / ".wh..wh..opq") for parent in target.parents}
        for digest in reversed(release.layers):
            with tarfile.open(
                fileobj=io.BytesIO(self.blob(f"blobs/{digest}", digest))
            ) as archive:
                for member in archive.getmembers():
                    if member.name.lstrip("./") != "usr/local/bin/trmnl-liquid-cli":
                        continue
                    if not member.isfile():
                        raise UpdateError(
                            "The released Liquid CLI is not a regular file."
                        )
                    source = archive.extractfile(member)
                    if source is None:
                        raise UpdateError("The CLI file has no archive payload.")
                    return source.read(), digest
                paths = {
                    member.name.removeprefix("./").rstrip("/")
                    for member in archive.getmembers()
                }
                if paths & whiteouts:
                    raise UpdateError("An image layer removed the Liquid CLI binary.")
        raise UpdateError("The released image contains no Liquid CLI binary.")


def run(arguments: list[str], cwd: Path | None = None) -> str:
    return subprocess.check_output(arguments, cwd=cwd, text=True).strip()


def library_provenance(extracted: Path, version: str) -> dict[str, str]:
    gem_info = json_object(
        fetch(
            f"https://rubygems.org/api/v2/rubygems/trmnl-liquid/versions/{version}.json"
        )
    )
    gem = fetch(f"https://rubygems.org/downloads/trmnl-liquid-{version}.gem")
    digest = hashlib.sha256(gem).hexdigest()
    if gem_info.get("sha") != digest:
        raise UpdateError("The published Liquid gem does not match its checksum.")
    with tarfile.open(fileobj=io.BytesIO(gem)) as archive:
        data = archive.extractfile("data.tar.gz")
        if data is None:
            raise UpdateError("The Liquid gem has no source archive.")
        with tarfile.open(fileobj=io.BytesIO(data.read())) as sources:
            count = 0
            for member in sources.getmembers():
                if not member.isfile():
                    continue
                source = sources.extractfile(member)
                local = extracted / "library" / member.name
                if (
                    source is None
                    or not local.is_file()
                    or local.read_bytes() != source.read()
                ):
                    raise UpdateError(
                        f"The embedded Liquid gem differs at {member.name}."
                    )
                count += 1
    return {
        "library": f"trmnl-liquid {version}",
        "library_gem_sha256": digest,
        "library_comparison": f"All {count} source gem files match the embedded files byte for byte",
    }


def update(package: Path, force: bool) -> None:
    record = json_object((package / "source.json").read_bytes())
    platform = record["platform"]
    if not isinstance(platform, str):
        raise UpdateError("The provenance record has no platform.")
    registry = Registry()
    release = registry.latest(platform)
    if (
        record["image"] == f"{registry.repository}:{release.version}"
        and record["manifest_digest"] == release.manifest_digest
        and not force
    ):
        print(f"Liquid CLI is already on {release.version}.")
        return
    binary, layer = registry.binary(release)
    root = Path(run(["git", "rev-parse", "--show-toplevel"], cwd=package))
    with tempfile.TemporaryDirectory(prefix="liquid-cli-update-") as directory:
        temporary = Path(directory)
        image = temporary / "filesystem.dwarfs"
        image.write_bytes(embedded_filesystem(binary))
        expression = (
            f"(builtins.getFlake {json.dumps(str(root))}).packages.aarch64-linux.trmnl-liquid-cli.extractSource "
            f'(builtins.path {{ path = {json.dumps(str(image))}; name = "trmnl-liquid-cli-filesystem"; }})'
        )
        extracted = Path(
            run(
                [
                    "nix",
                    "build",
                    "--impure",
                    "--expr",
                    expression,
                    "--no-link",
                    "--print-out-paths",
                ]
            )
        )
        raw = (extracted / "trmnl-liquid-cli.rb").read_bytes()
        normalized = raw.rstrip(b"\n") + b"\n"
        lockfile = (extracted / "Gemfile.lock").read_bytes()
        match = re.search(rb"^    trmnl-liquid \(([^)]+)\)$", lockfile, re.MULTILINE)
        if match is None:
            raise UpdateError("The released lockfile has no trmnl-liquid version.")
        version = match[1].decode()
        provenance = library_provenance(extracted, version)
        if record.get("library") != provenance["library"]:
            record.pop("library_git_tag", None)
            record.pop("library_git_commit", None)
        ruby = re.search(rb"ruby (\d+\.\d+\.\d+) \(", binary)
        if ruby is None:
            record.pop("ruby_version", None)
        if ruby is not None:
            record["ruby_version"] = ruby[1].decode()
        record.update(provenance)
        record.update(
            {
                "image": f"{registry.repository}:{release.version}",
                "manifest_digest": release.manifest_digest,
                "layer_digest": layer,
                "binary_sha256": hashlib.sha256(binary).hexdigest(),
                "cli_source_sha256": hashlib.sha256(raw).hexdigest(),
                "lockfile_sha256": hashlib.sha256(lockfile).hexdigest(),
                "packaged_cli_source_sha256": hashlib.sha256(normalized).hexdigest(),
                "packaged_cli_source_change": "Removed one trailing blank line; all other source bytes match the recovered file"
                if raw == normalized + b"\n"
                else "Normalised trailing newlines; all other source bytes match the recovered file",
            }
        )
        (temporary / "Gemfile").write_bytes((extracted / "Gemfile").read_bytes())
        (temporary / "Gemfile.lock").write_bytes(lockfile)
        run(["bundix"], cwd=temporary)
        files = {
            "trmnl-liquid-cli.rb": normalized,
            "Gemfile": (temporary / "Gemfile").read_bytes(),
            "Gemfile.lock": lockfile,
            "gemset.nix": (temporary / "gemset.nix").read_bytes(),
            "source.json": (json.dumps(record, indent=2) + "\n").encode(),
        }
        publish(package, files)
    print(f"Updated Liquid CLI to {release.version}.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    arguments = parser.parse_args()
    try:
        update(Path.cwd(), arguments.force)
    except (
        UpdateError,
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        parser.exit(1, f"Liquid CLI update failed: {error}\n")


if __name__ == "__main__":
    main()
