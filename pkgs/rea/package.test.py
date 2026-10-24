import json
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

PACKAGE = Path(sys.argv.pop(1))


class SetupPolicyTest(unittest.TestCase):
    def test_refresh_preserves_client_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            config = home / ".codex" / "config.toml"
            config.parent.mkdir()
            original = """model = "caller-model"

[mcp_servers.other]
command = "other"

[mcp_servers.rea]
command = "npx"
args = ["-y", "rea-agents@6.7.0", "mcp"]
startup_timeout_sec = 19
tool_timeout_sec = 999
default_tools_approval_mode = "prompt"
enabled_tools = ["binary_session", "inspect_binary"]
disabled_tools = ["capture_process_scenario"]
future_policy = { require_review = true }

[mcp_servers.rea.tools.binary_session]
approval_mode = "approve"

[mcp_servers.rea.env]
CALLER_SETTING = "retained"
"""
            config.write_text(original)
            environment = {
                "PATH": "",
                "HOME": str(home),
                "USERPROFILE": str(home),
                "CODEX_HOME": str(config.parent),
                "XDG_CONFIG_HOME": str(home / ".config"),
            }
            command = [
                str(PACKAGE / "bin" / "rea"),
                "setup",
                "--client",
                "codex",
                "--skill=false",
                "--json",
            ]

            def run(*arguments):
                result = subprocess.run(
                    [*command, *arguments],
                    env=environment,
                    cwd=home,
                    capture_output=True,
                    text=True,
                    timeout=60,
                    check=True,
                )
                return json.loads(result.stdout)

            self.assertEqual(run("--dry-run")["status"], "planned")
            self.assertEqual(config.read_text(), original)
            self.assertEqual(sorted(config.parent.iterdir()), [config])

            self.assertEqual(run("--yes")["status"], "ready")
            expected = tomllib.loads(original)
            expected["mcp_servers"]["rea"].update(
                command=str(PACKAGE / "lib/node_modules/rea-agents/scripts/rea.mjs"),
                args=["mcp"],
            )
            configured = config.read_text()
            self.assertEqual(tomllib.loads(configured), expected)
            self.assertEqual(Path(f"{config}.rea.backup").read_text(), original)

            self.assertEqual(run("--yes")["appliedActions"], [])
            self.assertEqual(config.read_text(), configured)

            invalid = configured.replace(
                'default_tools_approval_mode = "prompt"',
                'default_tools_approval_mode = "invalid"',
            )
            self.assertNotEqual(invalid, configured)
            config.write_text(invalid)
            before = sorted(config.parent.iterdir())
            refused = subprocess.run(
                [*command, "--yes"],
                env=environment,
                cwd=home,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(config.read_text(), invalid)
            self.assertEqual(sorted(config.parent.iterdir()), before)


if __name__ == "__main__":
    unittest.main()
