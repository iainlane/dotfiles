"""Relock a pnpm workspace at the versions selected by Renovate."""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path

LOCKFILE = Path("pnpm-lock.yaml")
WORKSPACE = Path("pnpm-workspace.yaml")
DEPENDENCY_FIELDS = ("dependencies", "devDependencies", "optionalDependencies")
CATALOG_PREFIX = "pnpm.catalog."
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[\w.-]+)?(?:\+[\w.-]+)?")
INSTALL = ["pnpm", "install", "--lockfile-only", "--ignore-scripts"]


@dataclass(frozen=True)
class Target:
    file: Path
    path: tuple[str, ...]
    lock_path: tuple[str, ...]
    version: str


def read_yaml(path: Path) -> dict:
    return (
        json.loads(
            subprocess.check_output(["yq", "-o=json", ".", str(path)], text=True)
        )
        or {}
    )


def entry(document: dict, path: tuple[str, ...]):
    for key in path:
        document = document.get(key) or {}
    return document


def set_yaml(path: Path, changes: list[dict]) -> None:
    if changes:
        subprocess.run(
            [
                "yq",
                "-i",
                "env(changes)[] as $change ireduce (.; setpath($change.path; $change.value))",
                str(path),
            ],
            env={**os.environ, "changes": json.dumps(changes)},
            check=True,
        )


def targets(
    upgrades: list[dict], directory: Path, manifests: set[Path]
) -> list[Target]:
    workspace = read_yaml(WORKSPACE)
    selected: dict[tuple[str, ...], Target] = {}
    for upgrade in upgrades:
        if upgrade.get("manager") != "npm":
            continue
        package_file = Path(upgrade["packageFile"])
        if not package_file.is_relative_to(directory):
            continue
        file = package_file.relative_to(directory)
        field, name = upgrade["depType"], upgrade["depName"]
        version = upgrade.get("newVersion")
        if not version or not VERSION.fullmatch(version):
            raise ValueError(f"{package_file}: {name} has no exact npm version")
        if file == WORKSPACE and field.startswith(CATALOG_PREFIX):
            catalog = field.removeprefix(CATALOG_PREFIX)
            path = (
                ("catalog", name)
                if catalog == "default" and name in workspace.get("catalog", {})
                else ("catalogs", catalog, name)
            )
            lock_path = ("catalogs", catalog, name)
        elif file in manifests and field in DEPENDENCY_FIELDS:
            path = (field, name)
            lock_path = ("importers", file.parent.as_posix(), *path)
        else:
            raise ValueError(
                f"{package_file}: unsupported Renovate dependency {field}.{name}"
            )
        target = Target(file, path, lock_path, version)
        if lock_path in selected and selected[lock_path] != target:
            raise ValueError(
                f"{package_file}: conflicting Renovate versions for {name}"
            )
        selected[lock_path] = target
    if not selected:
        raise ValueError(f"{directory}: no npm upgrades in Renovate's data")
    return list(selected.values())


def pin(targets: list[Target], restore: ExitStack) -> dict[Target, str]:
    by_file = defaultdict(list)
    for target in targets:
        by_file[target.file].append(target)
    ranges = {}
    for file, selected in by_file.items():
        original = file.read_bytes()
        restore.callback(file.write_bytes, original)
        document = read_yaml(file) if file == WORKSPACE else json.loads(original)
        changes = []
        for target in selected:
            specifier = entry(document, target.path)
            if not isinstance(specifier, str):
                raise TypeError(f"{file}: missing version range for {target.path[-1]}")
            ranges[target] = specifier
            exact = target.version
            if specifier.startswith("npm:"):
                exact = f"{specifier.rsplit('@', 1)[0]}@{exact}"
            if file == WORKSPACE:
                changes.append({"path": target.path, "value": exact})
            else:
                document[target.path[0]][target.path[1]] = exact
        if file == WORKSPACE:
            set_yaml(file, changes)
        else:
            file.write_text(json.dumps(document))
    return ranges


def registry_resolution(resolution: dict) -> str | None:
    """Ignore peer context and retain the identity of an aliased registry package."""
    value = resolution.get("version", "").split("(", 1)[0]
    if VERSION.fullmatch(value.rsplit("@", 1)[-1]):
        return value
    return None


def check_other_versions(
    before: dict, after: dict, updated: set[tuple[str, ...]]
) -> None:
    for importer, previous in before.get("importers", {}).items():
        for field in DEPENDENCY_FIELDS:
            for name, old in previous.get(field, {}).items():
                path = ("importers", importer, field, name)
                current = entry(after, path)
                specifier = old.get("specifier", "")
                if specifier.startswith("catalog:"):
                    catalog = specifier.removeprefix("catalog:") or "default"
                    if ("catalogs", catalog, name) in updated:
                        continue
                if path in updated:
                    continue
                old_version, current_version = map(registry_resolution, (old, current))
                if old_version and current_version and old_version != current_version:
                    raise ValueError(
                        f"{importer}: {name} changed from {old_version} to "
                        f"{current_version} without a Renovate upgrade"
                    )


def relock(upgrades: Path, directory: Path, manifests: set[Path]) -> None:
    selected = targets(json.loads(upgrades.read_text()), directory, manifests)
    before = read_yaml(LOCKFILE)
    # Resolve all requested versions together, including across workspace members.
    # Keep pnpm's resolutions and peer snapshots, then put the requested ranges
    # back in the manifests and the specifiers that pnpm recorded for them.
    with ExitStack() as restore:
        ranges = pin(selected, restore)
        subprocess.run([*INSTALL, "--no-frozen-lockfile"], check=True)
    after = read_yaml(LOCKFILE)
    check_other_versions(before, after, {target.lock_path for target in selected})
    changes = []
    for target, specifier in ranges.items():
        locked = entry(after, target.lock_path)
        expected = target.version
        if specifier.startswith("npm:"):
            expected = f"{specifier[4:].rsplit('@', 1)[0]}@{expected}"
        if registry_resolution(locked) != expected:
            raise ValueError(
                f"{target.file}: {target.path[-1]} resolved to "
                f"{locked.get('version', 'nothing')}, expected {expected}"
            )
        if locked["specifier"] != specifier:
            changes.append(
                {"path": (*target.lock_path, "specifier"), "value": specifier}
            )
    set_yaml(LOCKFILE, changes)
    subprocess.run([*INSTALL, "--frozen-lockfile"], check=True)


if __name__ == "__main__":
    root, metadata, *manifests = sys.argv[1:]
    try:
        relock(
            Path(metadata),
            Path.cwd().relative_to(Path(root).resolve()),
            set(map(Path, manifests)),
        )
    except (
        OSError,
        ValueError,
        TypeError,
        KeyError,
        subprocess.CalledProcessError,
    ) as error:
        sys.exit(f"Renovate pnpm relock: {error}")
