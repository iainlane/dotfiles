import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


def probe():
    agent = Path(os.environ["PI_CODING_AGENT_DIR"])
    session = Path(os.environ["PI_CODING_AGENT_SESSION_DIR"])
    session.mkdir(parents=True, exist_ok=True)
    (session / "probe").write_text("private state")
    result = {
        "args": sys.argv[2:],
        "cwd": os.getcwd(),
        "home": os.environ["HOME"],
        "agent": str(agent),
        "mode": stat.S_IMODE(agent.stat().st_mode),
        "collections": {
            name: (agent / name).is_symlink()
            for name in ["managed-extensions", "packages", "prompts", "themes", "skills"]
        },
        "auth": json.loads((agent / "auth.json").read_text()),
        "models": json.loads((agent / "models.json").read_text()),
        "keys": json.loads((agent / "keybindings.json").read_text()),
        "footer": json.loads((agent / "session-footer.json").read_text()),
        "pretty": os.environ["PRETTY_CONFIG_DIR"],
        "lens": os.environ["PI_LENS_CONFIG_PATH"],
        "todo": json.loads((Path(os.environ["XDG_CONFIG_HOME"]) / "rpiv-todo/config.json").read_text()),
        "helper": (Path(os.environ["XDG_CONFIG_HOME"]) / "helper/config").read_text(),
    }
    if "--detach" in sys.argv:
        subprocess.Popen([sys.executable, __file__, "--retained", str(agent), os.getcwd()], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    print(json.dumps(result))
    if "--fail" in sys.argv:
        sys.exit(7)


if len(sys.argv) > 1 and sys.argv[1] == "--retained":
    agent, root = map(Path, sys.argv[2:])
    deadline = time.monotonic() + 20
    while not (root / "release-child").exists() and time.monotonic() < deadline:
        time.sleep(0.025)
    (root / "retained-child").write_text((agent / "settings.json").read_text())
    sys.exit()


if len(sys.argv) > 1 and sys.argv[1] == "--probe":
    probe()
    sys.exit()

LAUNCHER, PREVIEW, NORMAL = sys.argv[1:]
sys.argv = sys.argv[:1]


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="pi bundle test ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.home = self.root / "home"
        self.agent = self.home / ".pi/agent"
        self.agent.mkdir(parents=True)
        self.xdg = self.home / "config"
        (self.xdg / "helper").mkdir(parents=True)
        (self.xdg / "helper/config").write_text("existing helper configuration")
        (self.xdg / "rpiv-todo").mkdir()
        (self.xdg / "rpiv-todo/config.json").write_text('{"widget": {"enabled": true}}')
        (self.agent / "settings.json").symlink_to(Path(NORMAL) / ".pi/agent/settings.json")
        for name in ["extensions", "packages", "prompts", "themes", "skills"]:
            (self.agent / name).symlink_to(Path(NORMAL) / ".pi/agent" / name)
        (self.agent / "auth.json").write_text(json.dumps({
            "static": {"type": "api_key", "key": "fixture-key", "env": {"TOKEN": "fixture"}, "unexpected": "never-copy-extra"},
            "oauth": {"type": "oauth", "access": "never-copy-access", "refresh": "never-copy-refresh", "expires": 4102444800000},
            "invalid": {"type": "api_key", "key": 1},
            "primitive": "never-copy-primitive",
            "invalid-env": {"type": "api_key", "key": "never-copy-key", "env": {"BAD": 1}},
        }))
        (self.agent / "mcp-auth.json").write_text("never-copy-mcp")
        (self.agent / "models.json").write_text('{"providers": {}}')
        (self.agent / "keybindings.json").write_text('{"app.interrupt": "escape"}')
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "TMPDIR": str(self.root),
            "XDG_CONFIG_HOME": str(self.xdg),
            "PI_CODING_AGENT_DIR": str(self.agent),
            "PI_CODING_AGENT_SESSION_DIR": str(self.agent / "sessions"),
        }

    def run_launcher(self, *args):
        before = {
            path.name: (path.readlink() if path.is_symlink() else path.read_bytes())
            for path in self.agent.iterdir()
        }
        result = subprocess.run([LAUNCHER, *args], cwd=self.root, env=self.env, text=True, capture_output=True)
        after = {
            path.name: (path.readlink() if path.is_symlink() else path.read_bytes())
            for path in self.agent.iterdir()
        }
        self.assertEqual(before, after)
        self.assertNotIn("never-copy", result.stdout + result.stderr)
        self.assertTrue(result.stdout, result.stderr)
        return result, json.loads(result.stdout)

    def test_collections_and_state(self):
        (self.root / "~profile").symlink_to(self.agent)
        for source, home in [
            (str(self.agent), self.home),
            ("~/.pi/agent", self.home),
            ("~", self.agent),
            ("home/.pi/agent", self.home),
            ("~profile", self.home),
        ]:
            with self.subTest(source=source):
                self.env["PI_CODING_AGENT_DIR"] = source
                self.env["HOME"] = str(home)
                self.assertEqual(sorted(path.name for path in Path(PREVIEW).iterdir()), [".config", ".pi", ".pi-lens"])
                result, actual = self.run_launcher("argument with spaces", "--mode", "rpc")
                runtime = Path(actual["agent"])
                self.assertNotEqual(runtime, self.agent)
                self.assertEqual(actual, {
                    "args": ["argument with spaces", "--mode", "rpc"],
                    "cwd": str(self.root),
                    "home": str(home),
                    "agent": str(runtime),
                    "mode": 0o700,
                    "collections": dict.fromkeys(["managed-extensions", "packages", "prompts", "themes", "skills"], True),
                    "auth": {"static": {"type": "api_key", "key": "fixture-key", "env": {"TOKEN": "fixture"}}},
                    "models": {"providers": {}},
                    "keys": {"app.interrupt": "escape"},
                    "footer": {"preset": "rich", "persistence": "session"},
                    "pretty": str(runtime),
                    "lens": str(Path(PREVIEW) / ".pi-lens/config.json"),
                    "todo": {"widget": {"enabled": False}},
                    "helper": "existing helper configuration",
                })
                self.assertEqual(result.returncode, 0)
                self.assertTrue((runtime / "sessions/probe").is_file())
                for name in actual["collections"]:
                    self.assertEqual((runtime / name).resolve(), (Path(PREVIEW) / ".pi/agent" / name).resolve())
                self.assertFalse((runtime / "extensions").is_symlink())
                self.assertTrue((runtime / "extensions/subagent").is_symlink())
                permission = runtime / "extensions/pi-permission-system/config.json"
                self.assertEqual(json.loads(permission.read_text()), {"authorizerChain": ["auto-review"], "permission": {"*": "allow", "bash": "ask"}})
                self.assertEqual(stat.S_IMODE(permission.stat().st_mode), 0o600)
                self.assertFalse((runtime / "mcp-auth.json").exists())
                self.assertEqual(stat.S_IMODE((runtime / "auth.json").stat().st_mode), 0o600)

    def test_bundle_variants(self):
        def contents(root):
            result = {}
            for path in Path(root).rglob("*"):
                relative = str(path.relative_to(root))
                if relative == ".pi/agent/extensions/subagent/config.json":
                    config = json.loads(path.read_text())
                    config.pop("defaultSessionDir", None)
                    result[relative] = config
                    continue
                if path.is_symlink() and path.is_dir():
                    result[relative] = str(path.resolve())
                    continue
                if path.is_file():
                    result[relative] = path.read_bytes()
            return result

        normal_contents = contents(NORMAL)
        preview_contents = contents(PREVIEW)
        footer_path = ".pi/agent/session-footer.json"
        self.assertEqual(
            (json.loads(normal_contents[footer_path]), json.loads(preview_contents[footer_path])),
            ({"preset": "rich"}, {"preset": "rich", "persistence": "session"}),
        )
        preview_contents[footer_path] = normal_contents[footer_path]
        self.assertEqual(normal_contents, preview_contents)
        normal = json.loads((Path(NORMAL) / ".pi/agent/extensions/subagent/config.json").read_text())
        preview = json.loads((Path(PREVIEW) / ".pi/agent/extensions/subagent/config.json").read_text())
        self.assertEqual(normal, {**preview, "defaultSessionDir": "~/.pi/agent/sessions/subagent"})

    def test_detached_child_reads_after_parent_exit(self):
        result, _ = self.run_launcher("--detach")
        self.assertEqual(result.returncode, 0)
        (self.root / "release-child").touch()
        retained = self.root / "retained-child"
        deadline = time.monotonic() + 10
        while not retained.exists() and time.monotonic() < deadline:
            time.sleep(0.025)
        self.assertEqual(retained.read_bytes(), (Path(PREVIEW) / ".pi/agent/settings.json").read_bytes())

    def test_failure_and_repeated_launches(self):
        first, a = self.run_launcher("--fail")
        second, b = self.run_launcher("--version")
        self.assertEqual([first.returncode, second.returncode], [7, 0])
        self.assertNotEqual(a["agent"], b["agent"])
        self.assertTrue(Path(a["agent"]).is_dir())

    def test_invalid_or_missing_auth(self):
        for source in ["invalid never-copy-auth", "[]", None]:
            with self.subTest(source=source):
                path = self.agent / "auth.json"
                if source is None:
                    path.unlink()
                else:
                    path.write_text(source)
                result, actual = self.run_launcher()
                self.assertEqual((result.returncode, actual["auth"]), (0, {}))


unittest.main()
