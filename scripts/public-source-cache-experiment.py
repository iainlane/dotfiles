import argparse
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import urlencode, urlsplit

PUBLIC_TARBALL_HOSTS = {"api.flakehub.com", "releases.nixos.org"}


def output(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def public_references(lock: dict) -> dict[str, tuple[str, str]]:
    nodes = lock["nodes"]
    private = nodes[lock["root"]]["inputs"].get("secrets")
    sources = {}
    for name, node in nodes.items():
        if name == private or "locked" not in node:
            continue
        entry = node["locked"]
        nar_hash = entry.get("narHash", "")
        if not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", nar_hash):
            continue
        kind = entry.get("type")
        if kind == "github" and entry.get("host", "github.com") == "github.com":
            owner, repo, revision = (entry[k] for k in ("owner", "repo", "rev"))
            if not all(
                re.fullmatch(r"[A-Za-z0-9._-]+", part) for part in (owner, repo)
            ):
                continue
            if not re.fullmatch(r"[0-9a-f]{40}", revision):
                continue
            reference = f"github:{owner}/{repo}/{revision}"
        elif kind == "tarball":
            url = urlsplit(entry["url"])
            if (
                url.scheme != "https"
                or url.netloc not in PUBLIC_TARBALL_HOSTS
                or url.query
                or url.fragment
            ):
                continue
            reference = f"tarball+{url.geturl()}"
        else:
            continue
        path = output(
            "nix-store",
            "--print-fixed-path",
            "--recursive",
            "sha256",
            nar_hash,
            "source",
        )
        sources[path] = (f"{reference}?{urlencode({'narHash': nar_hash})}", nar_hash)
    return sources


def present(sources: dict[str, tuple[str, str]]) -> list[str]:
    if not sources:
        return []
    invalid = set(
        output(
            "nix-store", "--check-validity", "--print-invalid", *sources
        ).splitlines()
    )
    return sorted(sources.keys() - invalid)


def seed(
    sources: dict[str, tuple[str, str]], requested: list[str], directory: Path
) -> None:
    paths = sorted(set(requested))
    if not paths or set(paths) - sources.keys():
        raise ValueError("The cache requires paths from the public lockfile manifest.")
    for path in paths:
        reference, nar_hash = sources[path]
        result = json.loads(
            output(
                "nix",
                "flake",
                "prefetch",
                "--json",
                "--option",
                "access-tokens",
                "",
                "--option",
                "netrc-file",
                "/dev/null",
                "--option",
                "allow-import-from-derivation",
                "false",
                reference,
            )
        )
        if result["storePath"] != path or result["hash"] != nar_hash:
            raise ValueError(f"Prefetch did not reproduce {path}.")
    if output("nix-store", "--query", "--references", *paths):
        raise ValueError("Public source paths must not reference other store paths.")
    directory.mkdir(parents=True)
    subprocess.run(
        ["nix", "copy", "--to", f"{directory.as_uri()}?compression=zstd", "--", *paths],
        check=True,
    )
    (directory / "paths.txt").write_text("\n".join(paths) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("lockfile", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("present")
    cache = commands.add_parser("seed")
    cache.add_argument("manifest", type=Path)
    cache.add_argument("directory", type=Path)
    args = parser.parse_args()
    sources = public_references(json.loads(args.lockfile.read_text()))
    if args.command == "present":
        print(json.dumps(present(sources), separators=(",", ":")))
        return
    seed(sources, json.loads(args.manifest.read_text()), args.directory)


if __name__ == "__main__":
    main()
