"""A pnpm for the lock updater's tests, which resolves from a fake registry.

`FAKE_REGISTRY` is a JSON file that maps each package name to its versions, and
each version to its `dependencies`. The project's overrides apply as in pnpm:
`name` everywhere, and `parent>name` only to the dependencies of `parent`. An
override or a manifest entry of the form `file:.nix-providers/<tarball>`
installs the package in that tarball, and its manifest supplies the package's
dependencies.

`install --lockfile-only` keeps the version that the lockfile records for a
dependency of an importer or of a package while it still satisfies the range.
`update --recursive --lockfile-only --no-save` chooses the newest
version in each range. Both write pnpm-lock.yaml and change nothing else.
"""

import fnmatch
import json
import os
import subprocess
import sys
import tarfile
from pathlib import Path

COMMANDS = {
    ("install", "--lockfile-only", "--no-frozen-lockfile", "--ignore-scripts"): True,
    (
        "update",
        "--recursive",
        "--lockfile-only",
        "--no-save",
        "--ignore-scripts",
    ): False,
}
FIELDS = ["dependencies", "devDependencies", "optionalDependencies"]

Version = tuple[int, int, int]


class Failure(Exception):
    pass


def read_yaml(path: Path) -> dict:
    if not path.exists():
        return {}
    output = subprocess.check_output(["yq", "-o=json", ".", str(path)], text=True)
    return json.loads(output) or {}


def parse(version: str) -> Version:
    major, minor, patch = (int(part) for part in version.split("."))
    return major, minor, patch


def satisfies(version: str, specifier: str) -> bool:
    if specifier in ("", "*", "latest"):
        return True
    operator = specifier[0] if specifier[0] in "^~" else ""
    parts = [int(part) for part in specifier[len(operator) :].split(".")]
    lower = tuple(parts + [0] * (3 - len(parts)))
    if not operator and len(parts) == 3:
        return parse(version) == lower
    if operator == "^":
        index = next(
            (index for index, part in enumerate(parts) if part), len(parts) - 1
        )
    elif operator == "~":
        index = min(1, len(parts) - 1)
    else:
        index = len(parts) - 1
    upper = tuple(parts[:index] + [parts[index] + 1] + [0] * (2 - index))
    return lower <= parse(version) < upper


def package_name(key: str) -> str:
    return "@" + key[1:].split("@")[0] if key.startswith("@") else key.split("@")[0]


class Resolver:
    def __init__(self, keep_locked: bool) -> None:
        self.registry = json.loads(Path(os.environ["FAKE_REGISTRY"]).read_text())
        self.workspace = read_yaml(Path("pnpm-workspace.yaml"))
        self.overrides: dict[str, str] = self.workspace.get("overrides") or {}
        lockfile = read_yaml(Path("pnpm-lock.yaml")) if keep_locked else {}
        # The locked version of each dependency, keyed by the importer or the
        # package that depends on it.
        self.locked: dict[str, dict[str, str]] = {
            f"importer:{directory}": {
                name: entry["version"]
                for field in FIELDS
                for name, entry in (importer.get(field) or {}).items()
            }
            for directory, importer in (lockfile.get("importers") or {}).items()
        } | {
            key: snapshot.get("dependencies") or {}
            for key, snapshot in (lockfile.get("snapshots") or {}).items()
        }
        self.packages: dict[str, dict] = {}
        self.snapshots: dict[str, dict] = {}

    def choose(self, name: str, specifier: str, locked: str | None) -> str:
        if name not in self.registry:
            raise Failure(f"ERR_PNPM_FETCH_404  {name} is not in the registry.")
        versions = [
            version for version in self.registry[name] if satisfies(version, specifier)
        ]
        if locked is not None:
            version = locked.split("(")[0].rsplit("@", 1)[-1]
            if version in versions:
                return version
        if not versions:
            raise Failure(
                f"ERR_PNPM_NO_MATCHING_VERSION  No version of {name} matches {specifier}."
            )
        return max(versions, key=parse)

    def resolve(
        self, name: str, specifier: str, parent: str | None, owner: str
    ) -> str | None:
        """Resolves a dependency of `owner`, an importer or a package, and
        returns the version that the lockfile records for it, or None when an
        override removes it. `parent` is the name of the package that depends on
        it, for the scoped overrides."""
        locked = self.locked.get(owner, {}).get(name)
        scoped = self.overrides.get(f"{parent}>{name}") if parent else None
        specifier = scoped or self.overrides.get(name) or specifier
        if specifier == "-":
            return None
        if specifier.startswith("file:"):
            target, dependencies = self.tarball(specifier[len("file:") :])
            resolution = {"tarball": specifier}
            version = specifier
        elif specifier.startswith("npm:"):
            alias = specifier[len("npm:") :]
            target = package_name(alias)
            version = self.choose(target, alias[len(target) + 1 :] or "*", locked)
            dependencies = self.registry[target][version].get("dependencies", {})
            resolution = {"integrity": f"sha512-{target}-{version}"}
        else:
            target = name
            version = self.choose(name, specifier, locked)
            dependencies = self.registry[name][version].get("dependencies", {})
            resolution = {"integrity": f"sha512-{name}-{version}"}

        key = f"{target}@{version}"
        if key not in self.packages:
            self.packages[key] = {"resolution": resolution}
            self.snapshots[key] = {}
            resolved = self.resolve_all(dependencies, target, key)
            if resolved:
                self.snapshots[key] = {"dependencies": resolved}
        return version if target == name else key

    def resolve_all(
        self, dependencies: dict[str, str], parent: str, owner: str
    ) -> dict[str, str]:
        resolved = {}
        for name, specifier in sorted(dependencies.items()):
            version = self.resolve(name, specifier, parent, owner)
            if version is not None:
                resolved[name] = version
        return resolved

    def tarball(self, path: str) -> tuple[str, dict[str, str]]:
        if not Path(path).exists():
            raise Failure(f"ENOENT  {path} does not exist.")
        with tarfile.open(path) as archive:
            member = archive.extractfile("package/package.json")
            if member is None:
                raise Failure(f"{path} has no package.json.")
            manifest = json.load(member)
        dependencies = manifest.get("dependencies", {}) | manifest.get(
            "optionalDependencies", {}
        )
        return manifest["name"], dependencies

    def importers(self) -> dict[str, dict]:
        patterns = self.workspace.get("packages") or []
        candidates = sorted(
            str(path.parent)
            for path in Path(".").glob("**/package.json")
            if ".nix-providers" not in path.parts and "node_modules" not in path.parts
        )
        members = ["."] + [
            directory
            for directory in candidates
            if any(
                fnmatch.fnmatch(directory, pattern)
                for pattern in patterns
                if not pattern.startswith("!")
            )
            and not any(
                fnmatch.fnmatch(directory, pattern[1:])
                for pattern in patterns
                if pattern.startswith("!")
            )
        ]
        importers = {}
        for directory in dict.fromkeys(members):
            manifest = json.loads((Path(directory) / "package.json").read_text())
            importer = {}
            for field in FIELDS:
                entries = {}
                for name, specifier in sorted(manifest.get(field, {}).items()):
                    version = self.resolve(
                        name, specifier, None, f"importer:{directory}"
                    )
                    if version is not None:
                        entries[name] = {"specifier": specifier, "version": version}
                if entries:
                    importer[field] = entries
            importers[directory] = importer
        return importers


def main() -> int:
    keep_locked = COMMANDS.get(tuple(sys.argv[1:]))
    if keep_locked is None:
        print(
            f"The fake pnpm does not support: {' '.join(sys.argv[1:])}", file=sys.stderr
        )
        return 1
    resolver = Resolver(keep_locked)
    try:
        importers = resolver.importers()
    except Failure as error:
        print(error, file=sys.stderr)
        return 1
    lockfile: dict = {"lockfileVersion": "9.0"}
    if resolver.overrides:
        lockfile["overrides"] = resolver.overrides
    lockfile |= {
        "importers": importers,
        "packages": dict(sorted(resolver.packages.items())),
        "snapshots": dict(sorted(resolver.snapshots.items())),
    }
    yaml = subprocess.run(
        ["yq", "-P", "-o=yaml", "."],
        input=json.dumps(lockfile),
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    Path("pnpm-lock.yaml").write_text(yaml)
    return 0


if __name__ == "__main__":
    sys.exit(main())
