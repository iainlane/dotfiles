import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

from update_runner import Outcome, Runner, Snapshot, input_groups, render, require_clean


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
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "owned").write_text("staged\n")
            subprocess.run(["git", "-C", str(root), "add", "owned"], check=True)
            with self.assertRaisesRegex(ValueError, "owned"):
                require_clean(root, ["owned"])


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
        for name in ["caddy", "pi"]:
            directory = self.root / "pkgs" / name
            directory.mkdir(parents=True)
            (directory / "source").write_text("old")
        (self.root / "flake.lock").write_text(
            json.dumps({"nixpkgs": "old", "llm-agents": "old"})
        )
        (self.root / "flake.nix").write_text("unchanged")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(self.root), "commit", "-qm", "initial"], check=True
        )
        (self.root / "librechat-password").write_text("unrelated")
        self.runner = Runner(self.root, "fixture")
        metadata = {
            name: {
                "refresh": True,
                "paths": [f"pkgs/{name}"],
                "program": name,
                "input": None,
            }
            for name in ["caddy", "pi"]
        }
        self.metadata_patch = patch.object(
            self.runner, "metadata", return_value=metadata
        )
        self.metadata_patch.start()
        self.addCleanup(self.metadata_patch.stop)
        plan_patch = patch.object(
            self.runner,
            "plan",
            return_value={
                "refreshOrder": ["caddy", "pi"],
                "dependencies": {"caddy": [], "pi": []},
            },
        )
        plan_patch.start()
        self.addCleanup(plan_patch.stop)

    def test_failed_input_restores_its_refreshes_and_keeps_independent_success(
        self,
    ) -> None:
        calls = []

        def command(args: list[str]) -> subprocess.CompletedProcess[str]:
            if args[:3] == ["nix", "flake", "update"]:
                lock = json.loads((self.root / "flake.lock").read_text())
                lock[args[3]] = "new"
                (self.root / "flake.lock").write_text(json.dumps(lock))
            return subprocess.CompletedProcess(args, 0, "")

        def execute(name: str, args: list[str]) -> Outcome:
            calls.append((name, args))
            lock = json.loads((self.root / "flake.lock").read_text())
            (self.root / f"pkgs/{name}/source").write_text(lock["llm-agents"])
            if lock["nixpkgs"] == "new":
                (self.root / "pkgs/caddy/partial").write_text("partial")
                return Outcome(name, 1, "Cannot refresh Caddy.")
            return Outcome(name)

        with (
            patch.object(self.runner, "command", side_effect=command),
            patch.object(self.runner, "execute", side_effect=execute),
            patch.object(
                self.runner, "plan", return_value={"refreshOrder": ["caddy", "pi"]}
            ),
        ):
            failed = self.runner.input_transaction(["nixpkgs"])
            accepted = self.runner.input_transaction(["llm-agents"])
        self.assertEqual(
            {
                "failed": failed,
                "accepted": accepted,
                "lock": json.loads((self.root / "flake.lock").read_text()),
                "caddy": (self.root / "pkgs/caddy/source").read_text(),
                "pi": (self.root / "pkgs/pi/source").read_text(),
                "partial": (self.root / "pkgs/caddy/partial").exists(),
                "unrelated": (self.root / "librechat-password").read_text(),
                "calls": calls,
            },
            {
                "failed": Outcome("nixpkgs", 1, "caddy: Cannot refresh Caddy."),
                "accepted": Outcome("llm-agents", changed=True),
                "lock": {"nixpkgs": "old", "llm-agents": "new"},
                "caddy": "new",
                "pi": "new",
                "partial": False,
                "unrelated": "unrelated",
                "calls": [
                    ("caddy", ["--refresh"]),
                    ("caddy", ["--refresh"]),
                    ("pi", ["--refresh"]),
                ],
            },
        )

    def test_a_later_input_failure_preserves_an_earlier_accepted_lock(self) -> None:
        def command(args: list[str]) -> subprocess.CompletedProcess[str]:
            if args[:3] == ["nix", "flake", "update"]:
                lock = json.loads((self.root / "flake.lock").read_text())
                lock[args[3]] = "new"
                (self.root / "flake.lock").write_text(json.dumps(lock))
            return subprocess.CompletedProcess(args, 0, "")

        with (
            patch.object(self.runner, "command", side_effect=command),
            patch.object(
                self.runner,
                "refresh",
                side_effect=[[], [Outcome("caddy", 1, "Hash discovery failed.")]],
            ),
        ):
            accepted = self.runner.input_transaction(["llm-agents"])
            failed = self.runner.input_transaction(["nixpkgs"])
        self.assertEqual(
            (accepted, failed, json.loads((self.root / "flake.lock").read_text())),
            (
                Outcome("llm-agents", changed=True),
                Outcome("nixpkgs", 1, "caddy: Hash discovery failed."),
                {"nixpkgs": "old", "llm-agents": "new"},
            ),
        )

    def test_a_failed_coupled_update_restores_both_inputs(self) -> None:
        original = (self.root / "flake.lock").read_bytes()

        def command(args: list[str]) -> subprocess.CompletedProcess[str]:
            if args[:3] == ["nix", "flake", "update"]:
                lock = json.loads(original)
                lock.update(dict.fromkeys(args[3:], "new"))
                (self.root / "flake.lock").write_text(json.dumps(lock))
                return subprocess.CompletedProcess(args, 0, "")
            return subprocess.CompletedProcess(args, 1, "")

        with (
            patch.object(self.runner, "command", side_effect=command),
            patch.object(self.runner, "refresh", return_value=[]),
        ):
            failed = self.runner.input_transaction(
                ["lanzaboote", "nixpkgs-measured-boot"]
            )
        self.assertEqual(
            (failed.status, (self.root / "flake.lock").read_bytes()), (1, original)
        )

    def test_a_failed_consumer_refresh_restores_its_provider_update(self) -> None:
        def execute(name: str, _args: list[str]) -> Outcome:
            (self.root / f"pkgs/{name}/source").write_text("new")
            return (
                Outcome(name, 1, "Consumer refresh failed.")
                if name == "pi"
                else Outcome(name)
            )

        plan = {
            "refreshOrder": ["caddy", "pi"],
            "dependencies": {"caddy": [], "pi": ["caddy"]},
        }
        with (
            patch.object(self.runner, "plan", return_value=plan),
            patch.object(self.runner, "execute", side_effect=execute),
            patch.object(
                self.runner,
                "command",
                return_value=subprocess.CompletedProcess([], 0, ""),
            ),
        ):
            result = self.runner.package_transaction("caddy", [])
        self.assertEqual(
            {
                "result": result,
                "sources": [
                    (self.root / f"pkgs/{name}/source").read_text()
                    for name in ["caddy", "pi"]
                ],
                "notices": self.runner.outcomes,
            },
            {
                "result": Outcome("caddy", 1, "pi: Consumer refresh failed."),
                "sources": ["old", "old"],
                "notices": [],
            },
        )

    def test_failed_candidate_evaluation_rolls_back_a_package_update(self) -> None:
        def execute(name: str, _args: list[str]) -> Outcome:
            (self.root / "pkgs/caddy/source").write_text("invalid")
            return Outcome(name)

        with (
            patch.object(self.runner, "execute", side_effect=execute),
            patch.object(
                self.runner,
                "command",
                return_value=subprocess.CompletedProcess([], 1, ""),
            ),
        ):
            result = self.runner.package_transaction("caddy", [])
        self.assertEqual(
            (result.status, (self.root / "pkgs/caddy/source").read_text()), (1, "old")
        )

    def test_failed_provider_skips_dependents_but_not_independent_updates(self) -> None:
        plan = {
            "order": ["provider", "dependent", "independent"],
            "dependencies": {
                "provider": [],
                "dependent": ["provider"],
                "independent": [],
            },
        }
        with (
            patch.object(self.runner, "plan", return_value=plan),
            patch.object(
                self.runner,
                "package_transaction",
                side_effect=[Outcome("provider", 1, "Failed."), Outcome("independent")],
            ) as execute,
        ):
            self.runner.packages(False)
        self.assertEqual(
            (execute.call_args_list, self.runner.outcomes),
            (
                [call("provider", []), call("independent", [])],
                [
                    Outcome("provider", 1, "Failed."),
                    Outcome(
                        "dependent", 1, "Skipped because a required provider failed."
                    ),
                    Outcome("independent"),
                ],
            ),
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
