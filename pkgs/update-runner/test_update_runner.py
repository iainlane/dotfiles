import json
import os
import subprocess
import tempfile
import unittest
from collections.abc import Callable
from pathlib import Path

from update_runner import (
    DirtyPathsError,
    LockGraph,
    Outcome,
    Runner,
    Snapshot,
    input_groups,
    render,
    require_clean,
)


class SnapshotTest(unittest.TestCase):
    def test_restores_only_owned_files_and_preserves_the_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(
                ["git", "-C", str(root), "config", "user.name", "Test"], check=True
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "config",
                    "user.email",
                    "test@example.invalid",
                ],
                check=True,
            )
            package = root / "pkgs/fixture"
            package.mkdir(parents=True)
            original = package / "source.json"
            original.write_text("original\n")
            original.chmod(0o755)
            (package / "link").symlink_to("source.json")
            (root / "unrelated").write_text("before\n")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(
                ["git", "-C", str(root), "commit", "-qm", "initial"], check=True
            )
            (root / "unrelated").write_text("staged\n")
            subprocess.run(["git", "-C", str(root), "add", "unrelated"], check=True)
            (root / "librechat-password").write_text("unrelated private file\n")
            (package / "existing-private.txt").write_text("untouched")
            require_clean(root, ["pkgs/fixture"])
            snapshot = Snapshot(root, ["pkgs/fixture"])
            original.unlink()
            (package / "link").unlink()
            (package / "new.json").write_text("partial\n")
            snapshot.include_new_files()
            indexed = subprocess.check_output(
                ["git", "-C", str(root), "ls-files"], text=True
            )
            snapshot.restore()
            self.assertEqual(
                {
                    "indexed": indexed,
                    "private": (package / "existing-private.txt").read_text(),
                    "source": original.read_text(),
                    "mode": original.stat().st_mode & 0o777,
                    "link": os.readlink(package / "link"),
                    "new": (package / "new.json").exists(),
                    "unrelated": (root / "unrelated").read_text(),
                    "password": (root / "librechat-password").read_text(),
                    "staged": subprocess.check_output(
                        ["git", "-C", str(root), "diff", "--cached", "--name-only"],
                        text=True,
                    ),
                },
                {
                    "indexed": "pkgs/fixture/link\npkgs/fixture/new.json\npkgs/fixture/source.json\nunrelated\n",
                    "private": "untouched",
                    "source": "original\n",
                    "mode": 0o755,
                    "link": "source.json",
                    "new": False,
                    "unrelated": "staged\n",
                    "password": "unrelated private file\n",
                    "staged": "unrelated\n",
                },
            )

    def test_refuses_dirty_owned_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def git(*args: str) -> None:
                subprocess.run(["git", "-C", str(root), *args], check=True)

            git("init", "-q")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.invalid")
            (root / "modified").write_text("committed\n")
            (root / "unrelated").write_text("committed\n")
            git("add", ".")
            git("commit", "-qm", "initial")
            (root / "modified").write_text("unstaged\n")
            (root / "unrelated").write_text("unstaged\n")
            (root / "added").write_text("staged\n")
            git("add", "added")
            with self.assertRaises(DirtyPathsError) as raised:
                require_clean(root, ["added", "modified"])
            self.assertEqual(
                (type(raised.exception), raised.exception.paths),
                (DirtyPathsError, ["added", "modified"]),
            )


SYSTEM = "fixture"
STORE = Path("/nix/store")

# A fake updater takes its command-line arguments and returns its exit status
# and standard output.
Updater = Callable[[list[str]], tuple[int, str]]


class FakeNix:
    """Runs the commands that `Runner` issues against a fixture repository.

    The metadata lists each updater with its package directory, and `nix build`
    returns a store path for each updater. Running the program in that path
    calls the updater. `nix flake update` sets each named input in flake.lock to
    its entry in `releases`, or to "new". The evaluation gate fails when
    flake.lock or a package's `source` file contains "invalid".
    """

    def __init__(
        self,
        root: Path,
        plan: dict,
        updaters: dict[str, Updater],
        *,
        maintained: tuple[str, ...] = (),
        releases: dict[str, str] | None = None,
    ) -> None:
        self.root = root
        self.plan = plan
        self.updaters = updaters
        self.releases = releases or {}
        self.commands: list[list[str]] = []
        self.metadata = {
            name: {
                "refresh": True,
                "paths": [f"pkgs/{name}"],
                "program": name,
                "input": None,
                "lockfileMaintenance": name in maintained,
            }
            for name in updaters
        }

    def run(self, args: list[str]) -> subprocess.CompletedProcess[str]:
        self.commands.append(args)
        scripts = f".#legacyPackages.{SYSTEM}.updaterScripts."
        match args:
            case ["nix", "eval", "--json", installable] if (
                installable == f".#legacyPackages.{SYSTEM}.updaterMetadata"
            ):
                return subprocess.CompletedProcess(args, 0, json.dumps(self.metadata))
            case ["nix", "run", ".#update-plan", "--", "describe"]:
                return subprocess.CompletedProcess(args, 0, json.dumps(self.plan))
            case ["nix", "build", "--no-link", "--print-out-paths", installable] if (
                installable.removeprefix(scripts) in self.updaters
            ):
                name = installable.removeprefix(scripts)
                return subprocess.CompletedProcess(args, 0, f"{STORE / name}\n")
            case ["nix", "flake", "update", *inputs]:
                lock = json.loads((self.root / "flake.lock").read_text())
                roots = lock["nodes"][lock["root"]]["inputs"]
                for name in inputs:
                    node = roots.setdefault(name, name)
                    lock["nodes"].setdefault(node, {})["locked"] = {
                        "rev": self.releases.get(name, "new")
                    }
                (self.root / "flake.lock").write_text(json.dumps(lock))
                return subprocess.CompletedProcess(args, 0, "")
            case ["bash", "scripts/check-evaluation.bash"]:
                return subprocess.CompletedProcess(args, int(self.invalid()), "")
            case [program, *arguments] if updater := self.updater(program):
                status, output = updater(arguments)
                return subprocess.CompletedProcess(args, status, output)
        return subprocess.CompletedProcess(args, 127, "")

    def updater(self, program: str) -> Updater | None:
        path = Path(program)
        name = path.parent.parent.name
        if path.parent.parent.parent != STORE or path.parent.name != "bin":
            return None
        if name not in self.updaters or self.metadata[name]["program"] != path.name:
            return None
        return self.updaters[name]

    def invalid(self) -> bool:
        lock = json.loads((self.root / "flake.lock").read_text())
        sources = [path.read_text() for path in self.root.glob("pkgs/*/source")]
        revisions = [
            node.get("locked", {}).get("rev") for node in lock["nodes"].values()
        ]
        return "invalid" in [*revisions, *sources]


class TransactionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(
            ["git", "-C", str(self.root), "config", "core.excludesFile", "/dev/null"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(self.root), "config", "user.name", "Test"], check=True
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(self.root),
                "config",
                "user.email",
                "test@example.invalid",
            ],
            check=True,
        )
        for name in ["caddy", "pi", "independent"]:
            directory = self.root / "pkgs" / name
            directory.mkdir(parents=True)
            (directory / "source").write_text("old")
        (self.root / "flake.lock").write_text(
            json.dumps(
                {
                    "version": 7,
                    "root": "root",
                    "nodes": {
                        "root": {
                            "inputs": {"nixpkgs": "nixpkgs", "llm-agents": "llm-agents"}
                        },
                        "nixpkgs": {"locked": {"rev": "old"}},
                        "llm-agents": {"locked": {"rev": "old"}},
                    },
                }
            )
        )
        (self.root / "flake.nix").write_text("unchanged")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(self.root), "commit", "-qm", "initial"], check=True
        )
        (self.root / "librechat-password").write_text("unrelated")

    def runner(self, nix: FakeNix) -> Runner:
        return Runner(self.root, SYSTEM, nix, stage=False)

    def lock(self) -> dict[str, str]:
        lock = json.loads((self.root / "flake.lock").read_text())
        nodes = lock["nodes"]
        return {
            name: nodes[node]["locked"]["rev"]
            for name, node in nodes[lock["root"]]["inputs"].items()
        }

    def source(self, name: str) -> str:
        return (self.root / f"pkgs/{name}/source").read_text()

    def write(self, name: str, source: str) -> None:
        (self.root / f"pkgs/{name}/source").write_text(source)

    def test_successful_batch_relocks_refreshes_and_validates_once(self) -> None:
        def refresh(args: list[str]) -> tuple[int, str]:
            revisions = self.lock()
            self.write("caddy", f"{revisions['nixpkgs']}/{revisions['llm-agents']}")
            return 0, ""

        nix = FakeNix(self.root, {"refreshOrder": ["caddy"]}, {"caddy": refresh})
        runner = self.runner(nix)
        runner.update_inputs([["nixpkgs"], ["llm-agents"]])
        self.assertEqual(
            (
                [
                    args
                    for args in nix.commands
                    if args[:3] == ["nix", "flake", "update"]
                ],
                [args for args in nix.commands if args[-1] == "--refresh"],
                nix.commands.count(["bash", "scripts/check-evaluation.bash"]),
                runner.outcomes,
                self.source("caddy"),
            ),
            (
                [["nix", "flake", "update", "nixpkgs", "llm-agents"]],
                [[str(STORE / "caddy/bin/caddy"), "--refresh"]],
                1,
                [Outcome("nixpkgs", changed=True), Outcome("llm-agents", changed=True)],
                "new/new",
            ),
        )

    def test_failed_batch_restores_partial_files_and_preserves_coupled_groups(
        self,
    ) -> None:
        partial = self.root / "pkgs/caddy/partial"

        def refresh(args: list[str]) -> tuple[int, str]:
            revisions = self.lock()
            self.write("caddy", f"{revisions['nixpkgs']}/{revisions['llm-agents']}")
            if "nixpkgs-measured-boot" in revisions:
                partial.write_text("partial")
            return 0, ""

        nix = FakeNix(
            self.root,
            {"refreshOrder": ["caddy"]},
            {"caddy": refresh},
            releases={"nixpkgs-measured-boot": "invalid"},
        )
        runner = Runner(self.root, SYSTEM, nix, stage=True)
        coupled = ["lanzaboote", "nixpkgs-measured-boot"]
        runner.update_inputs([["llm-agents"], coupled, ["nixpkgs"]])
        staged = subprocess.check_output(
            ["git", "-C", str(self.root), "diff", "--cached", "--name-only"], text=True
        )
        self.assertEqual(
            (
                [
                    args[3:]
                    for args in nix.commands
                    if args[:3] == ["nix", "flake", "update"]
                ],
                runner.outcomes,
                self.lock(),
                self.source("caddy"),
                partial.exists(),
                staged.splitlines(),
            ),
            (
                [
                    ["llm-agents", *coupled, "nixpkgs"],
                    ["llm-agents"],
                    [*coupled, "nixpkgs"],
                    coupled,
                    ["nixpkgs"],
                ],
                [
                    Outcome("llm-agents", changed=True),
                    Outcome(
                        "lanzaboote, nixpkgs-measured-boot",
                        1,
                        "The candidate input update failed the no-build evaluation gate.",
                    ),
                    Outcome("nixpkgs", changed=True),
                ],
                {"nixpkgs": "new", "llm-agents": "new"},
                "new/new",
                False,
                ["flake.lock", "pkgs/caddy/source"],
            ),
        )

    def test_unchanged_batch_does_not_plan_refreshes_or_evaluate_targets(self) -> None:
        nix = FakeNix(
            self.root, {}, {}, releases={"nixpkgs": "old", "llm-agents": "old"}
        )
        runner = self.runner(nix)
        runner.update_inputs([["nixpkgs"], ["llm-agents"]])
        self.assertEqual(
            (nix.commands, render(runner.outcomes)),
            (
                [
                    [
                        "nix",
                        "eval",
                        "--json",
                        f".#legacyPackages.{SYSTEM}.updaterMetadata",
                    ],
                    ["nix", "flake", "update", "nixpkgs", "llm-agents"],
                ],
                "No updates were needed.\n",
            ),
        )

    def test_failed_input_restores_its_refreshes_and_keeps_independent_success(
        self,
    ) -> None:
        def refresh(name: str) -> Updater:
            def run(args: list[str]) -> tuple[int, str]:
                if args != ["--refresh"]:
                    return 1, "Unsupported updater arguments."
                lock = self.lock()
                self.write(name, lock["llm-agents"])
                if lock["nixpkgs"] == "new":
                    (self.root / f"pkgs/{name}/partial").write_text("partial")
                    return 1, f"Cannot refresh {name}."
                return 0, ""

            return run

        runner = self.runner(
            FakeNix(
                self.root,
                {"refreshOrder": ["caddy", "pi"]},
                {name: refresh(name) for name in ["caddy", "pi"]},
            )
        )
        failed = runner.input_transaction(["nixpkgs"])
        accepted = runner.input_transaction(["llm-agents"])
        self.assertEqual(
            {
                "failed": failed,
                "accepted": accepted,
                "lock": self.lock(),
                "caddy": self.source("caddy"),
                "pi": self.source("pi"),
                "partial": (self.root / "pkgs/caddy/partial").exists(),
                "unrelated": (self.root / "librechat-password").read_text(),
            },
            {
                "failed": Outcome("nixpkgs", 1, "caddy: Cannot refresh caddy."),
                "accepted": Outcome("llm-agents", changed=True),
                "lock": {"nixpkgs": "old", "llm-agents": "new"},
                "caddy": "new",
                "pi": "new",
                "partial": False,
                "unrelated": "unrelated",
            },
        )

    def test_refreshes_only_affected_packages_in_provider_order(self) -> None:
        calls: list[tuple[str, list[str]]] = []

        def refresh(name: str) -> Updater:
            def run(args: list[str]) -> tuple[int, str]:
                calls.append((name, args))
                self.write(name, "refreshed")
                return 0, ""

            return run

        names = ["independent", "caddy", "pi"]
        runner = self.runner(
            FakeNix(
                self.root,
                {
                    "refreshOrder": names,
                    "dependencies": {
                        "independent": [],
                        "caddy": ["provider"],
                        "pi": ["caddy", "provider"],
                    },
                    "inputDependencies": {
                        "independent": ["nixpkgs"],
                        "provider": ["llm-agents"],
                        "caddy": [],
                        "pi": [],
                    },
                },
                {name: refresh(name) for name in names},
            )
        )
        result = runner.input_transaction(["llm-agents"])
        self.assertEqual(
            (result, calls, {name: self.source(name) for name in names}),
            (
                Outcome("llm-agents", changed=True),
                [("caddy", ["--refresh"]), ("pi", ["--refresh"])],
                {"independent": "old", "caddy": "refreshed", "pi": "refreshed"},
            ),
        )

    def test_a_later_input_failure_preserves_an_earlier_accepted_lock(self) -> None:
        def caddy(args: list[str]) -> tuple[int, str]:
            if self.lock()["nixpkgs"] == "new":
                return 1, "Hash discovery failed."
            return 0, ""

        runner = self.runner(
            FakeNix(
                self.root,
                {
                    "refreshOrder": ["caddy", "pi"],
                    "dependencies": {"caddy": [], "pi": []},
                    "inputDependencies": {"caddy": ["nixpkgs"], "pi": ["llm-agents"]},
                },
                {"caddy": caddy, "pi": lambda args: (0, "")},
            )
        )
        accepted = runner.input_transaction(["llm-agents"])
        failed = runner.input_transaction(["nixpkgs"])
        self.assertEqual(
            (accepted, failed, self.lock()),
            (
                Outcome("llm-agents", changed=True),
                Outcome("nixpkgs", 1, "caddy: Hash discovery failed."),
                {"nixpkgs": "old", "llm-agents": "new"},
            ),
        )

    def test_a_failed_coupled_update_restores_both_inputs(self) -> None:
        original = (self.root / "flake.lock").read_bytes()
        runner = self.runner(
            FakeNix(
                self.root,
                {
                    "refreshOrder": ["caddy", "pi"],
                    "dependencies": {"caddy": [], "pi": []},
                    "inputDependencies": {"caddy": ["nixpkgs"], "pi": ["llm-agents"]},
                },
                {
                    name: lambda args: (1, "An unaffected updater ran.")
                    for name in ["caddy", "pi"]
                },
                releases={"lanzaboote": "new", "nixpkgs-measured-boot": "invalid"},
            )
        )
        failed = runner.input_transaction(["lanzaboote", "nixpkgs-measured-boot"])
        self.assertEqual(
            (failed, (self.root / "flake.lock").read_bytes()),
            (
                Outcome(
                    "lanzaboote, nixpkgs-measured-boot",
                    1,
                    "The candidate input update failed the no-build evaluation gate.",
                ),
                original,
            ),
        )

    def test_a_failed_consumer_refresh_restores_its_provider_update(self) -> None:
        def caddy(args: list[str]) -> tuple[int, str]:
            self.write("caddy", "new")
            return 0, ""

        def pi(args: list[str]) -> tuple[int, str]:
            self.write("pi", "new")
            return 1, "Consumer refresh failed."

        runner = self.runner(
            FakeNix(
                self.root,
                {
                    "refreshOrder": ["caddy", "pi"],
                    "dependencies": {"caddy": [], "pi": ["caddy"]},
                },
                {"caddy": caddy, "pi": pi},
            )
        )
        result = runner.package_transaction("caddy", [])
        self.assertEqual(
            {
                "result": result,
                "sources": [self.source(name) for name in ["caddy", "pi"]],
                "notices": runner.outcomes,
            },
            {
                "result": Outcome("caddy", 1, "pi: Consumer refresh failed."),
                "sources": ["old", "old"],
                "notices": [],
            },
        )

    def test_failed_candidate_evaluation_rolls_back_a_package_update(self) -> None:
        def caddy(args: list[str]) -> tuple[int, str]:
            self.write("caddy", "invalid")
            return 0, ""

        runner = self.runner(
            FakeNix(
                self.root,
                {"refreshOrder": ["caddy"], "dependencies": {"caddy": []}},
                {"caddy": caddy},
            )
        )
        result = runner.package_transaction("caddy", [])
        self.assertEqual(
            (result, self.source("caddy")),
            (
                Outcome(
                    "caddy",
                    1,
                    "The candidate package update failed the no-build evaluation gate.",
                ),
                "old",
            ),
        )

    def test_failed_provider_skips_dependents_but_not_independent_updates(self) -> None:
        def update(name: str) -> Updater:
            def run(args: list[str]) -> tuple[int, str]:
                self.write(name, "updated")
                return 0, ""

            return run

        names = ["caddy", "pi", "independent"]
        runner = self.runner(
            FakeNix(
                self.root,
                {
                    "order": names,
                    "refreshOrder": names,
                    "dependencies": {"caddy": [], "pi": ["caddy"], "independent": []},
                },
                {
                    "caddy": lambda args: (1, "Failed."),
                    "pi": update("pi"),
                    "independent": update("independent"),
                },
            )
        )
        runner.packages(False)
        self.assertEqual(
            {
                "outcomes": runner.outcomes,
                "sources": {name: self.source(name) for name in names},
            },
            {
                "outcomes": [
                    Outcome("caddy", 1, "Failed."),
                    Outcome("pi", 1, "Skipped because a required provider failed."),
                    Outcome("independent", changed=True),
                ],
                "sources": {"caddy": "old", "pi": "old", "independent": "updated"},
            },
        )

    def test_lockfile_maintenance_reaches_only_the_updaters_that_support_it(
        self,
    ) -> None:
        def update(name: str, supported: list[list[str]]) -> Updater:
            def run(args: list[str]) -> tuple[int, str]:
                if args and args not in supported:
                    return 1, "Unsupported updater arguments."
                self.write(name, "maintained" if args else "updated")
                return 0, ""

            return run

        runner = self.runner(
            FakeNix(
                self.root,
                {
                    "order": ["caddy", "pi"],
                    "refreshOrder": ["caddy", "pi"],
                    "dependencies": {"caddy": [], "pi": []},
                },
                {
                    "caddy": update("caddy", []),
                    "pi": update("pi", [["--maintain-lockfile"]]),
                },
                maintained=("pi",),
            )
        )
        runner.packages(False, maintain_lockfiles=True)
        self.assertEqual(
            {
                "outcomes": runner.outcomes,
                "sources": {name: self.source(name) for name in ["caddy", "pi"]},
            },
            {
                "outcomes": [
                    Outcome("caddy", changed=True),
                    Outcome("pi", changed=True),
                ],
                "sources": {"caddy": "updated", "pi": "maintained"},
            },
        )


class LockGraphTest(unittest.TestCase):
    def test_compares_reachable_inputs_without_using_node_labels(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "flake.lock"

            def graph(revision: str, suffix: str) -> LockGraph:
                path.write_text(
                    json.dumps(
                        {
                            "version": 7,
                            "root": f"root{suffix}",
                            "nodes": {
                                f"root{suffix}": {
                                    "inputs": {
                                        "tools": f"tools{suffix}",
                                        "compiler": ["tools", "compiler"],
                                        "consumer": f"consumer{suffix}",
                                        "independent": f"independent{suffix}",
                                    }
                                },
                                f"tools{suffix}": {
                                    "inputs": {"compiler": f"compiler{suffix}"}
                                },
                                f"consumer{suffix}": {
                                    "inputs": {"compiler": ["compiler"]}
                                },
                                f"compiler{suffix}": {"locked": {"rev": revision}},
                                f"independent{suffix}": {"locked": {"rev": "same"}},
                            },
                        }
                    )
                )
                return LockGraph.read(path)

            before = graph("old", "")
            relabelled = graph("old", "_2")
            changed = graph("new", "_2")
            self.assertEqual(
                (
                    before.changes(relabelled),
                    before.changes(changed),
                    before.changes(changed, follow_aliases=False),
                ),
                (set(), {"compiler", "consumer", "tools"}, {"tools"}),
            )


class ReportTest(unittest.TestCase):
    def test_messages_do_not_need_changes_and_preserve_failure_details(self) -> None:
        self.assertEqual(
            render(
                [
                    Outcome("teamclaude", message="Review a release.\nKeep the fork."),
                    Outcome("nixpkgs", status=1, message="Caddy could not refresh."),
                    Outcome(
                        "dependent", status=1, message="Skipped after provider failed."
                    ),
                ]
            ),
            "## Update notices\n\n- teamclaude\n  > Review a release.\n  > Keep the fork.\n\n## Failed or skipped updates\n\n- nixpkgs\n  > Caddy could not refresh.\n- dependent\n  > Skipped after provider failed.\n",
        )

    def test_expands_coupled_inputs_and_follows_aliases(self) -> None:
        lock = {
            "nodes": {
                "root": {
                    "inputs": {
                        "lanzaboote": "l",
                        "nixpkgs-measured-boot": "n",
                        "hermes-agent": "h",
                        "uv2nix": ["hermes-agent", "uv2nix"],
                    }
                }
            }
        }
        self.assertEqual(
            input_groups(lock, ["uv2nix", "lanzaboote", "nixpkgs-measured-boot"]),
            [["hermes-agent"], ["lanzaboote", "nixpkgs-measured-boot"]],
        )


if __name__ == "__main__":
    unittest.main()
