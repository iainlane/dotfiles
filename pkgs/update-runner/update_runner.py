import argparse
import json
import os
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, TypedDict


class Operation(TypedDict):
    refresh: bool
    paths: list[str]
    program: str
    input: str | None
    lockfileMaintenance: bool


class MaintenancePlan(TypedDict):
    order: list[str]
    refreshOrder: list[str]
    dependencies: dict[str, list[str]]
    inputDependencies: dict[str, list[str] | None]


@dataclass(frozen=True)
class Outcome:
    name: str
    status: int = 0
    message: str = ""
    changed: bool = False


@dataclass(frozen=True)
class InputAttempt:
    outcome: Outcome
    updated_inputs: frozenset[str] = frozenset()


class DirtyPathsError(ValueError):
    def __init__(self, paths: list[str]) -> None:
        listing = "".join(f"{path}\n" for path in paths)
        super().__init__(
            f"Commit or stash changes in update-owned paths first:\n{listing}"
        )
        self.paths = paths


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True)


def files(root: Path, scopes: list[str], *, indexed: bool = False) -> set[str]:
    args = ["ls-files", "-z", "--cached"]
    if not indexed:
        args += ["--others", "--exclude-standard"]
    return set(filter(None, git(root, *args, "--", *scopes).split("\0")))


def require_clean(root: Path, scopes: list[str]) -> None:
    dirty: set[str] = set()
    for staged in ([], ["--cached"]):
        listing = git(root, "diff", *staged, "--name-only", "-z", "--", *scopes)
        dirty.update(filter(None, listing.split("\0")))
    if dirty:
        raise DirtyPathsError(sorted(dirty))


@dataclass(frozen=True)
class Entry:
    mode: int
    data: bytes | None
    target: str | None

    @classmethod
    def read(cls, path: Path) -> "Entry":
        mode = path.lstat().st_mode
        return cls(
            mode,
            None if stat.S_ISLNK(mode) else path.read_bytes(),
            os.readlink(path) if stat.S_ISLNK(mode) else None,
        )

    def restore(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_symlink() or path.is_file():
            path.unlink()
        if self.target is not None:
            path.symlink_to(self.target)
            return
        if self.data is None:
            raise ValueError(f"Missing snapshot contents for {path}")
        path.write_bytes(self.data)
        path.chmod(stat.S_IMODE(self.mode))


class Snapshot:
    def __init__(self, root: Path, scopes: list[str]) -> None:
        if not scopes or any(
            Path(scope).is_absolute() or ".." in Path(scope).parts for scope in scopes
        ):
            raise ValueError("Update ownership must use repository-relative paths.")
        self.root = root
        self.scopes = scopes
        self.indexed = files(root, scopes, indexed=True)
        self.entries = {
            name: Entry.read(root / name)
            for name in files(root, scopes)
            if (root / name).is_file() or (root / name).is_symlink()
        }

    def changed_files(self) -> list[str]:
        current = files(self.root, self.scopes)
        changed = []
        for name in current | self.entries.keys():
            path = self.root / name
            entry = Entry.read(path) if path.is_file() or path.is_symlink() else None
            if entry != self.entries.get(name):
                changed.append(name)
        return sorted(changed)

    def include_new_files(self) -> None:
        new = sorted(
            files(self.root, self.scopes)
            - self.entries.keys()
            - files(self.root, self.scopes, indexed=True)
        )
        if new:
            git(self.root, "add", "--intent-to-add", "--", *new)

    def restore(self) -> None:
        added_index = files(self.root, self.scopes, indexed=True) - self.indexed
        if added_index:
            git(self.root, "update-index", "--force-remove", "--", *sorted(added_index))
        for name in files(self.root, self.scopes) - self.entries.keys():
            path = self.root / name
            if path.is_file() or path.is_symlink():
                path.unlink()
        for name, entry in self.entries.items():
            entry.restore(self.root / name)


type LockReference = str | list[str]


class LockNode(TypedDict, total=False):
    inputs: dict[str, LockReference]


@dataclass(frozen=True)
class LockGraph:
    nodes: dict[str, LockNode]
    root: str

    @classmethod
    def read(cls, path: Path) -> "LockGraph":
        try:
            lock = json.loads(path.read_bytes())
            return cls(lock["nodes"], lock["root"])
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise ValueError(f"Could not read {path.name}: {error}") from error

    def inputs(self, node: str) -> dict[str, LockReference]:
        return self.nodes[node].get("inputs", {})

    def resolve(self, reference: LockReference) -> str:
        if isinstance(reference, str):
            return reference

        # A follows path starts at the root, even on a nested node.
        node = self.root
        for name in reference:
            node = self.resolve(self.inputs(node)[name])
        return node

    def equivalent(
        self,
        other: "LockGraph",
        left: LockReference,
        right: LockReference,
        *,
        follow_aliases: bool,
    ) -> bool:
        pending = [(left, right)]
        seen: set[tuple[str, str]] = set()
        while pending:
            left_ref, right_ref = pending.pop()
            if not follow_aliases and (
                isinstance(left_ref, list) or isinstance(right_ref, list)
            ):
                if left_ref != right_ref:
                    return False
                continue

            left_node, right_node = self.resolve(left_ref), other.resolve(right_ref)
            pair = (left_node, right_node)
            if pair in seen:
                continue
            seen.add(pair)
            old = {
                key: value
                for key, value in self.nodes[left_node].items()
                if key != "inputs"
            }
            new = {
                key: value
                for key, value in other.nodes[right_node].items()
                if key != "inputs"
            }
            old_inputs, new_inputs = self.inputs(left_node), other.inputs(right_node)
            if old != new or old_inputs.keys() != new_inputs.keys():
                return False
            pending.extend(
                (reference, new_inputs[name]) for name, reference in old_inputs.items()
            )
        return True

    def changes(self, other: "LockGraph", *, follow_aliases: bool = True) -> set[str]:
        before, after = self.inputs(self.root), other.inputs(other.root)
        return (before.keys() ^ after.keys()) | {
            name
            for name in before.keys() & after.keys()
            if not self.equivalent(
                other, before[name], after[name], follow_aliases=follow_aliases
            )
        }


def input_groups(lock: dict, requested: list[str]) -> list[list[str]]:
    roots = lock["nodes"][lock.get("root", "root")]["inputs"]
    coupled = ["lanzaboote", "nixpkgs-measured-boot"]
    groups: list[list[str]] = []
    for name in requested or sorted(roots):
        if name not in roots:
            raise ValueError(f"Unknown flake input: {name}")
        while isinstance(roots[name], list):
            name = roots[name][0]
        group = (
            coupled
            if name in coupled and all(member in roots for member in coupled)
            else [name]
        )
        if group not in groups:
            groups.append(group)
    return groups


def render(outcomes: list[Outcome]) -> str:
    sections = [
        (
            "Updated",
            [result for result in outcomes if result.status == 0 and result.changed],
        ),
        (
            "Update notices",
            [result for result in outcomes if result.status == 0 and result.message],
        ),
        (
            "Failed or skipped updates",
            [result for result in outcomes if result.status != 0],
        ),
    ]
    lines: list[str] = []
    for title, results in sections:
        if not results:
            continue
        if lines:
            lines.append("")
        lines += [f"## {title}", ""]
        for result in results:
            lines.append(f"- {result.name}")
            if result.message:
                lines += [f"  > {line}" for line in result.message.strip().splitlines()]
    return "\n".join(lines) + "\n" if lines else "No updates were needed.\n"


class Executor(Protocol):
    def run(self, args: list[str]) -> subprocess.CompletedProcess[str]: ...


class Processes:
    def __init__(self, root: Path) -> None:
        self.root = root

    def run(self, args: list[str]) -> subprocess.CompletedProcess[str]:
        print("+ " + " ".join(args), file=sys.stderr)
        return subprocess.run(
            args, cwd=self.root, stdout=subprocess.PIPE, text=True, check=False
        )


class Runner:
    def __init__(
        self, root: Path, system: str, executor: Executor, *, stage: bool
    ) -> None:
        self.root = root
        self.system = system
        self.executor = executor
        self.stage = stage
        self.outcomes: list[Outcome] = []

    def metadata(self) -> dict[str, Operation]:
        result = self.executor.run(
            ["nix", "eval", "--json", f".#legacyPackages.{self.system}.updaterMetadata"]
        )
        if result.returncode:
            raise ValueError("Could not evaluate updater metadata.")
        return json.loads(result.stdout)

    def plan(self) -> MaintenancePlan:
        result = self.executor.run(["nix", "run", ".#update-plan", "--", "describe"])
        if result.returncode:
            raise ValueError("Could not determine maintenance order.")
        return json.loads(result.stdout)

    def execute(self, name: str, args: list[str]) -> Outcome:
        metadata = self.metadata()
        operation = metadata[name]
        if "--refresh" in args and not operation["refresh"]:
            return Outcome(name, 1, "This updater does not support --refresh.")
        result = self.executor.run(
            [
                "nix",
                "build",
                "--no-link",
                "--print-out-paths",
                f".#legacyPackages.{self.system}.updaterScripts.{name}",
            ]
        )
        if result.returncode:
            return Outcome(
                name, result.returncode, "Could not build the updater executable."
            )
        paths = result.stdout.strip().splitlines()
        if len(paths) != 1:
            return Outcome(name, 1, "Expected one updater executable output.")
        result = self.executor.run(
            [str(Path(paths[0]) / "bin" / operation["program"]), *args]
        )
        message = result.stdout.strip()
        if result.returncode and not message:
            message = f"Updater exited with status {result.returncode}; see the diagnostic logs."
        return Outcome(name, result.returncode, message)

    def accept(self, snapshot: Snapshot) -> list[str]:
        changed = snapshot.changed_files()
        snapshot.include_new_files()
        if self.stage and changed:
            git(self.root, "add", "--", *changed)
        return changed

    def dependent_refreshes(self, name: str) -> list[str]:
        plan = self.plan()
        return [
            other
            for other in plan["refreshOrder"]
            if name in plan["dependencies"][other]
        ]

    def input_refreshes(self, changed: set[str]) -> list[str]:
        plan = self.plan()
        order = plan["refreshOrder"]
        inputs = plan.get("inputDependencies")
        if inputs is None:
            return order

        affected = {
            name
            for name, dependencies in inputs.items()
            if dependencies is None or changed.intersection(dependencies)
        }
        return [
            name
            for name in order
            if name in affected or affected.intersection(plan["dependencies"][name])
        ]

    def refresh(self, names: list[str]) -> list[Outcome]:
        results: list[Outcome] = []
        for name in names:
            snapshot = Snapshot(self.root, self.metadata()[name]["paths"])
            result = self.execute(name, ["--refresh"])
            results.append(result)
            if result.status:
                break
            snapshot.include_new_files()
        return results

    def update_inputs(self, groups: list[list[str]]) -> None:
        if not groups:
            return

        attempt = self._attempt_inputs([name for group in groups for name in group])
        result = attempt.outcome
        if len(groups) == 1:
            self.outcomes.append(result)
            return
        if result.status:
            print(
                f"Splitting failed batch of {len(groups)} input groups: {result.message}",
                file=sys.stderr,
            )
            middle = len(groups) // 2
            self.update_inputs(groups[:middle])
            self.update_inputs(groups[middle:])
            return

        updated = [
            Outcome(", ".join(group), changed=True)
            for group in groups
            if attempt.updated_inputs.intersection(group)
        ]
        if not updated:
            self.outcomes.append(result)
            return
        self.outcomes.extend(updated)
        if result.message:
            self.outcomes.append(Outcome(result.name, message=result.message))

    def input_transaction(
        self,
        group: list[str],
        updater: str | None = None,
        args: list[str] | None = None,
    ) -> Outcome:
        return self._attempt_inputs(group, updater, args).outcome

    def _attempt_inputs(
        self,
        inputs: list[str],
        updater: str | None = None,
        args: list[str] | None = None,
    ) -> InputAttempt:
        metadata = self.metadata()
        scopes = ["flake.lock", "flake.nix"] + [
            path
            for operation in metadata.values()
            if operation["refresh"]
            for path in operation["paths"]
        ]
        snapshot = Snapshot(self.root, sorted(set(scopes)))
        name = ", ".join(inputs)
        try:
            lock = self.root / "flake.lock"
            before = LockGraph.read(lock)
            result = (
                self.execute(updater, args or [])
                if updater
                else self.executor.run(["nix", "flake", "update", *inputs])
            )
            status = result.status if isinstance(result, Outcome) else result.returncode
            message = (
                result.message if isinstance(result, Outcome) else result.stdout.strip()
            )
            if status:
                raise ValueError(
                    message or "The input could not be relocked; see diagnostic logs."
                )
            changed_files = snapshot.changed_files()
            if not changed_files:
                return InputAttempt(Outcome(name, message=message))
            snapshot.include_new_files()
            after = LockGraph.read(lock)
            changed_inputs = before.changes(after)
            names = (
                self.plan()["refreshOrder"]
                if not changed_inputs and "flake.nix" in changed_files
                else self.input_refreshes(changed_inputs)
            )
            refreshed = self.refresh(names)
            failed = next((result for result in refreshed if result.status), None)
            if failed:
                raise ValueError(f"{failed.name}: {failed.message}")
            evaluation = self.executor.run(["bash", "scripts/check-evaluation.bash"])
            if evaluation.returncode:
                raise ValueError(
                    "The candidate input update failed the no-build evaluation gate."
                )
            updated_inputs = frozenset(before.changes(after, follow_aliases=False))
            changed = self.accept(snapshot)
            self.outcomes.extend(result for result in refreshed if result.message)
            return InputAttempt(
                Outcome(name, message=message, changed=bool(changed)), updated_inputs
            )
        except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
            snapshot.restore()
            return InputAttempt(Outcome(name, 1, str(error)))

    def package_transaction(self, name: str, args: list[str]) -> Outcome:
        metadata = self.metadata()
        operation = metadata[name]
        if operation["input"] is not None:
            lock = json.loads((self.root / "flake.lock").read_text())
            group = input_groups(lock, [operation["input"]])[0]
            return self.input_transaction(group, name, args)
        dependents = self.dependent_refreshes(name)
        scopes = operation["paths"] + [
            path for dependent in dependents for path in metadata[dependent]["paths"]
        ]
        snapshot = Snapshot(self.root, sorted(set(scopes)))
        refreshed: list[Outcome] = []
        try:
            result = self.execute(name, args)
            if result.status:
                snapshot.restore()
                return result
            snapshot.include_new_files()
            if snapshot.changed_files():
                refreshed = self.refresh(dependents)
                failed = next(
                    (refresh for refresh in refreshed if refresh.status), None
                )
                if failed:
                    raise ValueError(f"{failed.name}: {failed.message}")
                evaluation = self.executor.run(
                    ["bash", "scripts/check-evaluation.bash"]
                )
                if evaluation.returncode:
                    raise ValueError(
                        "The candidate package update failed the no-build evaluation gate."
                    )
            changed = self.accept(snapshot)
            self.outcomes.extend(refresh for refresh in refreshed if refresh.message)
            return Outcome(name, message=result.message, changed=bool(changed))
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            snapshot.restore()
            return Outcome(name, 1, str(error))

    def packages(self, refresh: bool, maintain_lockfiles: bool = False) -> None:
        plan = self.plan()
        metadata = self.metadata()
        failed: set[str] = set()
        for name in plan["refreshOrder" if refresh else "order"]:
            if refresh:
                args = ["--refresh"]
            elif maintain_lockfiles and metadata[name]["lockfileMaintenance"]:
                args = ["--maintain-lockfile"]
            else:
                args = []
            if failed.intersection(plan["dependencies"][name]):
                result = Outcome(name, 1, "Skipped because a required provider failed.")
            else:
                result = self.package_transaction(name, args)
            if result.status:
                failed.add(name)
            self.outcomes.append(result)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--system", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ["package", "packages", "inputs", "combined"]:
        subparser = commands.add_parser(command)
        subparser.add_argument("--stage", action="store_true")
        if command == "package":
            subparser.add_argument("name")
            subparser.add_argument("arguments", nargs=argparse.REMAINDER)
        if command in {"packages", "combined"}:
            modes = subparser.add_mutually_exclusive_group()
            if command == "packages":
                modes.add_argument("--refresh", action="store_true")
            modes.add_argument("--maintain-lockfiles", action="store_true")
        if command == "inputs":
            subparser.add_argument("names", nargs="*")
    arguments = parser.parse_args()
    try:
        root = Path(
            subprocess.check_output(
                ["git", "rev-parse", "--show-toplevel"], text=True
            ).strip()
        )
        runner = Runner(root, arguments.system, Processes(root), stage=arguments.stage)
        metadata = runner.metadata()
        refresh_names = [
            name for name, operation in metadata.items() if operation["refresh"]
        ]
        if arguments.command in {"inputs", "combined"}:
            selected = (
                refresh_names if arguments.command == "inputs" else list(metadata)
            )
            scopes = ["flake.lock", "flake.nix"]
        elif arguments.command == "package" and metadata[arguments.name]["input"]:
            selected = [arguments.name, *refresh_names]
            scopes = []
        elif arguments.command == "package":
            selected = [arguments.name, *runner.dependent_refreshes(arguments.name)]
            scopes = []
        else:
            selected = refresh_names if arguments.refresh else list(metadata)
            scopes = []
        scopes += [path for name in selected for path in metadata[name]["paths"]]
        require_clean(root, sorted(set(scopes)))
        if arguments.command == "package":
            result = runner.package_transaction(arguments.name, arguments.arguments)
            if result.message:
                print(result.message)
            for notice in runner.outcomes:
                if notice.message:
                    print(f"{notice.name}: {notice.message}")
            return 1 if result.status else 0
        if arguments.command in {"inputs", "combined"}:
            lock = json.loads((root / "flake.lock").read_text())
            names = arguments.names if arguments.command == "inputs" else []
            runner.update_inputs(input_groups(lock, names))
        if arguments.command in {"packages", "combined"}:
            runner.packages(
                arguments.command == "packages" and arguments.refresh,
                arguments.maintain_lockfiles,
            )
        sys.stdout.write(render(runner.outcomes))
        return int(any(result.status for result in runner.outcomes))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Update failed: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
