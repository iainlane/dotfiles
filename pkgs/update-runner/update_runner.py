import argparse
import json
import os
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict


class Operation(TypedDict):
    refresh: bool
    paths: list[str]
    program: str
    input: str | None


@dataclass(frozen=True)
class Outcome:
    name: str
    status: int = 0
    message: str = ""
    changed: bool = False


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True)


def files(root: Path, scopes: list[str], *, indexed: bool = False) -> set[str]:
    args = ["ls-files", "-z", "--cached"]
    if not indexed:
        args += ["--others", "--exclude-standard"]
    return set(filter(None, git(root, *args, "--", *scopes).split("\0")))


def require_clean(root: Path, scopes: list[str]) -> None:
    dirty = git(root, "status", "--porcelain", "--untracked-files=no", "--", *scopes)
    if dirty:
        raise ValueError(
            f"Commit or stash changes in update-owned paths first:\n{dirty}"
        )


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


class Runner:
    def __init__(self, root: Path, system: str, stage: bool = False) -> None:
        self.root = root
        self.system = system
        self.stage = stage
        self.outcomes: list[Outcome] = []

    def command(self, args: list[str]) -> subprocess.CompletedProcess[str]:
        print("+ " + " ".join(args), file=sys.stderr)
        return subprocess.run(
            args, cwd=self.root, stdout=subprocess.PIPE, text=True, check=False
        )

    def metadata(self) -> dict[str, Operation]:
        result = self.command(
            ["nix", "eval", "--json", f".#legacyPackages.{self.system}.updaterMetadata"]
        )
        if result.returncode:
            raise ValueError("Could not evaluate updater metadata.")
        return json.loads(result.stdout)

    def plan(self) -> dict:
        result = self.command(["nix", "run", ".#update-plan", "--", "describe"])
        if result.returncode:
            raise ValueError("Could not determine maintenance order.")
        return json.loads(result.stdout)

    def execute(self, name: str, args: list[str]) -> Outcome:
        metadata = self.metadata()
        operation = metadata[name]
        if "--refresh" in args and not operation["refresh"]:
            return Outcome(name, 1, "This updater does not support --refresh.")
        result = self.command(
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
        result = self.command(
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

    def refresh(self, names: list[str] | None = None) -> list[Outcome]:
        results: list[Outcome] = []
        for name in self.plan()["refreshOrder"] if names is None else names:
            snapshot = Snapshot(self.root, self.metadata()[name]["paths"])
            result = self.execute(name, ["--refresh"])
            results.append(result)
            if result.status:
                break
            snapshot.include_new_files()
        return results

    def input_transaction(
        self,
        group: list[str],
        updater: str | None = None,
        args: list[str] | None = None,
    ) -> Outcome:
        metadata = self.metadata()
        scopes = ["flake.lock", "flake.nix"] + [
            path
            for operation in metadata.values()
            if operation["refresh"]
            for path in operation["paths"]
        ]
        snapshot = Snapshot(self.root, sorted(set(scopes)))
        name = ", ".join(group)
        try:
            result = (
                self.execute(updater, args or [])
                if updater
                else self.command(["nix", "flake", "update", *group])
            )
            status = result.status if isinstance(result, Outcome) else result.returncode
            message = (
                result.message if isinstance(result, Outcome) else result.stdout.strip()
            )
            if status:
                raise ValueError(
                    message or "The input could not be relocked; see diagnostic logs."
                )
            if not snapshot.changed_files():
                return Outcome(name, message=message)
            snapshot.include_new_files()
            refreshed = self.refresh()
            failed = next((result for result in refreshed if result.status), None)
            if failed:
                raise ValueError(f"{failed.name}: {failed.message}")
            evaluation = self.command(["bash", "scripts/check-evaluation.bash"])
            if evaluation.returncode:
                raise ValueError(
                    "The candidate input update failed the no-build evaluation gate."
                )
            changed = self.accept(snapshot)
            self.outcomes.extend(result for result in refreshed if result.message)
            return Outcome(name, message=message, changed=bool(changed))
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            snapshot.restore()
            return Outcome(name, 1, str(error))

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
                evaluation = self.command(["bash", "scripts/check-evaluation.bash"])
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

    def packages(self, refresh: bool) -> None:
        plan = self.plan()
        failed: set[str] = set()
        for name in plan["refreshOrder" if refresh else "order"]:
            if failed.intersection(plan["dependencies"][name]):
                result = Outcome(name, 1, "Skipped because a required provider failed.")
            else:
                result = self.package_transaction(
                    name, ["--refresh"] if refresh else []
                )
            if result.status:
                failed.add(name)
            self.outcomes.append(result)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--system", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ["package", "packages", "inputs"]:
        subparser = commands.add_parser(command)
        subparser.add_argument("--stage", action="store_true")
        if command == "package":
            subparser.add_argument("name")
            subparser.add_argument("arguments", nargs=argparse.REMAINDER)
        if command == "packages":
            subparser.add_argument("--refresh", action="store_true")
        if command == "inputs":
            subparser.add_argument("names", nargs="*")
    arguments = parser.parse_args()
    try:
        root = Path(
            subprocess.check_output(
                ["git", "rev-parse", "--show-toplevel"], text=True
            ).strip()
        )
        runner = Runner(root, arguments.system, arguments.stage)
        metadata = runner.metadata()
        refresh_names = [
            name for name, operation in metadata.items() if operation["refresh"]
        ]
        if arguments.command == "inputs":
            selected = refresh_names
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
        if arguments.command == "inputs":
            lock = json.loads((root / "flake.lock").read_text())
            for group in input_groups(lock, arguments.names):
                runner.outcomes.append(runner.input_transaction(group))
        else:
            runner.packages(arguments.refresh)
        sys.stdout.write(render(runner.outcomes))
        return int(any(result.status for result in runner.outcomes))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Update failed: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
