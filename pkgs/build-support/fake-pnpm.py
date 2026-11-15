"""A pnpm for the lock updater's tests, which resolves from a fake registry.

`FAKE_REGISTRY` is a JSON file that maps each package name to its versions, and
each version to its `dependencies` and `peerDependencies`. The project's
overrides apply as in pnpm: `name` everywhere, and `parent>name` only to the
dependencies of `parent`. An override or a manifest entry of the form
`file:.nix-providers/<tarball>` installs the package in that tarball, and its
manifest supplies the package's dependencies and peers.

As in pnpm 10 with `autoInstallPeers: false`, a peer resolves to the package of
that name among the dependent's siblings or, failing that, among its ancestors'
dependencies. A package with resolved peers has a snapshot for each set of
peers: its key and its references append `(<peer>@<version>)` for each peer,
sorted by name, and the snapshot lists the peers among its dependencies. The
workspace's package patterns are globs in which `*` matches within one path
segment and `**` matches across segments.

`install --lockfile-only` keeps the version that the lockfile records for a
dependency of an importer or of a package while it still satisfies the range.
With `--frozen-lockfile`, it fails instead of changing the lockfile. `update
--recursive` chooses the newest version in each range. Without `--recursive`,
it updates only the root's dependencies and keeps the members' locked versions.
Without `--no-save`, it also writes the chosen versions into the manifests'
ranges. Without `--lockfile-only`, either command also installs each importer's
direct dependencies into its node_modules. None of the registry's packages has
scripts, so `--ignore-scripts` changes nothing.
"""

import json
import os
import subprocess
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path, PurePath

FIELDS = ["dependencies", "devDependencies", "optionalDependencies"]
OPTIONS = {
    "install": {
        "--lockfile-only",
        "--frozen-lockfile",
        "--no-frozen-lockfile",
        "--ignore-scripts",
    },
    "update": {"--recursive", "--lockfile-only", "--no-save", "--ignore-scripts"},
}

Version = tuple[int, int, int]


class Failure(Exception):
    pass


@dataclass(frozen=True)
class Command:
    name: str
    options: frozenset[str]

    @classmethod
    def parse(cls, arguments: list[str]) -> "Command":
        if not arguments or arguments[0] not in OPTIONS:
            raise Failure(f"The fake pnpm does not support: {' '.join(arguments)}")
        name, options = arguments[0], arguments[1:]
        unknown = [option for option in options if option not in OPTIONS[name]]
        if unknown:
            raise Failure(f" ERROR  Unknown option: '{unknown[0].lstrip('-')}'")
        return cls(name, frozenset(options))

    def keeps(self, directory: str) -> bool:
        """Whether the versions locked for the importer remain."""
        if self.name == "install":
            return True
        return "--recursive" not in self.options and directory != "."


@dataclass(frozen=True)
class Node:
    """A package chosen for a dependency, before its peers resolve."""

    target: str
    version: str
    resolution: dict[str, str]
    dependencies: dict[str, str]
    peers: dict[str, str]


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


def saved(specifier: str, version: str) -> str:
    """The range that `pnpm update` writes for a version, which keeps the
    operator of the previous range."""
    if specifier.startswith("~"):
        return f"~{version}"
    if specifier.count(".") == 2 and specifier[0].isdigit():
        return version
    return f"^{version}"


class Resolver:
    def __init__(self, command: Command) -> None:
        self.command = command
        self.registry = json.loads(Path(os.environ["FAKE_REGISTRY"]).read_text())
        self.workspace = read_yaml(Path("pnpm-workspace.yaml"))
        self.overrides: dict[str, str] = self.workspace.get("overrides") or {}
        lockfile = read_yaml(Path("pnpm-lock.yaml"))
        # The locked version of each dependency, keyed by the importer or the
        # snapshot that depends on it.
        self.locked: dict[str, dict[str, str]] = {
            f"importer:{directory}": {
                name: entry["version"]
                for field in FIELDS
                for name, entry in (importer.get(field) or {}).items()
            }
            for directory, importer in (lockfile.get("importers") or {}).items()
            if command.keeps(directory)
        }
        if command.name == "install":
            self.locked |= {
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

    def node(
        self, name: str, specifier: str, parent: str | None, owner: str
    ) -> Node | None:
        """Chooses the package for a dependency of `owner`, an importer or a
        snapshot, or returns None when an override removes it. `parent` is the
        name of the package that depends on it, for the scoped overrides."""
        locked = self.locked.get(owner, {}).get(name)
        scoped = self.overrides.get(f"{parent}>{name}") if parent else None
        specifier = scoped or self.overrides.get(name) or specifier
        if specifier == "-":
            return None
        if specifier.startswith("file:"):
            return self.tarball(specifier)
        target = name
        if specifier.startswith("npm:"):
            alias = specifier[len("npm:") :]
            target = package_name(alias)
            specifier = alias[len(target) + 1 :] or "*"
        version = self.choose(target, specifier, locked)
        manifest = self.registry[target][version]
        return Node(
            target,
            version,
            {"integrity": f"sha512-{target}-{version}"},
            manifest.get("dependencies", {}),
            manifest.get("peerDependencies", {}),
        )

    def tarball(self, specifier: str) -> Node:
        path = specifier[len("file:") :]
        if not Path(path).exists():
            raise Failure(f"ENOENT  {path} does not exist.")
        with tarfile.open(path) as archive:
            member = archive.extractfile("package/package.json")
            if member is None:
                raise Failure(f"{path} has no package.json.")
            manifest = json.load(member)
        return Node(
            manifest["name"],
            specifier,
            {"tarball": specifier},
            manifest.get("dependencies", {}) | manifest.get("optionalDependencies", {}),
            manifest.get("peerDependencies", {}),
        )

    def resolve_all(
        self,
        dependencies: dict[str, str],
        parent: str | None,
        owner: str,
        ancestors: list[dict[str, Node]],
    ) -> dict[str, str]:
        """Resolves the dependencies of `owner` and returns the reference that
        the lockfile records for each one. `ancestors` lists the dependencies
        of each package above `owner`, nearest first."""
        siblings = {}
        for name, specifier in sorted(dependencies.items()):
            node = self.node(name, specifier, parent, owner)
            if node is not None:
                siblings[name] = node
        scope = [siblings, *ancestors]
        return {
            name: self.reference(name, node, scope) for name, node in siblings.items()
        }

    def reference(self, name: str, node: Node, scope: list[dict[str, Node]]) -> str:
        peers = {}
        for peer in sorted(node.peers):
            level = next(
                (index for index, nodes in enumerate(scope) if peer in nodes), None
            )
            if level is not None:
                peers[peer] = self.reference(peer, scope[level][peer], scope[level:])
        version = node.version + "".join(
            f"({peer}@{reference})" for peer, reference in peers.items()
        )
        key = f"{node.target}@{version}"
        if key not in self.snapshots:
            self.snapshots[key] = {}
            package: dict = {"resolution": node.resolution}
            if node.peers:
                package["peerDependencies"] = node.peers
            self.packages[f"{node.target}@{node.version}"] = package
            resolved = self.resolve_all(node.dependencies, node.target, key, scope)
            if resolved or peers:
                self.snapshots[key] = {
                    "dependencies": dict(sorted((resolved | peers).items()))
                }
        return version if node.target == name else key

    def members(self) -> list[str]:
        patterns = self.workspace.get("packages") or []
        candidates = sorted(
            str(path.parent)
            for path in Path(".").glob("**/package.json")
            if ".nix-providers" not in path.parts and "node_modules" not in path.parts
        )
        return list(
            dict.fromkeys(
                ["."]
                + [
                    directory
                    for directory in candidates
                    if any(
                        PurePath(directory).full_match(pattern)
                        for pattern in patterns
                        if not pattern.startswith("!")
                    )
                    and not any(
                        PurePath(directory).full_match(pattern[1:])
                        for pattern in patterns
                        if pattern.startswith("!")
                    )
                ]
            )
        )

    def importers(self) -> dict[str, dict]:
        importers = {}
        for directory in self.members():
            manifest = json.loads((Path(directory) / "package.json").read_text())
            dependencies = {
                name: specifier
                for field in FIELDS
                for name, specifier in manifest.get(field, {}).items()
            }
            resolved = self.resolve_all(dependencies, None, f"importer:{directory}", [])
            importer = {}
            for field in FIELDS:
                entries = {
                    name: {"specifier": specifier, "version": resolved[name]}
                    for name, specifier in sorted(manifest.get(field, {}).items())
                    if name in resolved
                }
                if entries:
                    importer[field] = entries
            importers[directory] = importer
        return importers


def save(importers: dict[str, dict], overrides: dict[str, str]) -> None:
    """Writes each chosen registry version into the range of its manifest
    entry, as `pnpm update` does without `--no-save`."""
    for directory, importer in importers.items():
        path = Path(directory) / "package.json"
        manifest = json.loads(path.read_text())
        for field, entries in importer.items():
            for name, entry in entries.items():
                if name in overrides or not entry["version"][0].isdigit():
                    continue
                version = entry["version"].split("(")[0]
                manifest[field][name] = saved(entry["specifier"], version)
        path.write_text(json.dumps(manifest, indent=2) + "\n")


def install(importers: dict[str, dict]) -> None:
    """Writes the manifest of each importer's direct dependencies into its
    node_modules."""
    for directory, importer in importers.items():
        for entries in importer.values():
            for name, entry in entries.items():
                path = Path(directory) / "node_modules" / name / "package.json"
                path.parent.mkdir(parents=True, exist_ok=True)
                version = entry["version"].split("(")[0]
                path.write_text(json.dumps({"name": name, "version": version}) + "\n")


def yaml(value: dict) -> str:
    return subprocess.run(
        ["yq", "-P", "-o=yaml", "."],
        input=json.dumps(value),
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def main() -> int:
    try:
        command = Command.parse(sys.argv[1:])
        resolver = Resolver(command)
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
    path = Path("pnpm-lock.yaml")
    if "--frozen-lockfile" in command.options and read_yaml(path) != lockfile:
        print(
            'ERR_PNPM_OUTDATED_LOCKFILE  Cannot install with "frozen-lockfile" because pnpm-lock.yaml is not up to date with package.json',
            file=sys.stderr,
        )
        return 1
    path.write_text(yaml(lockfile))
    if command.name == "update" and "--no-save" not in command.options:
        save(importers, resolver.overrides)
    if "--lockfile-only" not in command.options:
        install(importers)
    return 0


if __name__ == "__main__":
    sys.exit(main())
