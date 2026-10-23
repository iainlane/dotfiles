import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

herdr, annotate_arg, links_arg, tui_arg = sys.argv[1:]
annotate = Path(annotate_arg)
links = Path(links_arg)
tui = Path(tui_arg)


def run(*args: str, **kwargs) -> str:
    return subprocess.check_output(args, text=True, **kwargs).strip()


manifest = tomllib.loads((annotate / "herdr-plugin.toml").read_text())
assert "build" not in manifest, "Nix must stage every runtime dependency"
assert (annotate / "bin/plannotator-tui.exe").resolve() == tui.resolve()
assert run(str(annotate / "bin/herdr-annotate.exe"), "--version") == "herdr-annotate 0.2.0"
assert run(str(annotate / "bin/plannotator-tui.exe"), "--version") == "plannotator-tui 0.9.4"
doc = next(pane for pane in manifest["panes"] if pane["id"] == "doc")
assert doc["command"] == [str(tui), "herdr", "pane"]
for action in manifest["actions"]:
    command = action["command"][0]
    executable = annotate / command if command.startswith("./") else Path(command)
    assert executable.is_absolute() and os.access(executable, os.X_OK), action

home = Path.cwd() / "home"
home.mkdir()
env = dict(os.environ, HOME=str(home))
env.pop("XDG_CONFIG_HOME", None)
env.pop("XDG_STATE_HOME", None)
for root in (annotate, links):
    run(herdr, "plugin", "link", str(root), "--enabled", env=env)
registry = json.loads(run(herdr, "plugin", "list", "--json", env=env))
registered = sorted(
    [plugin["plugin_id"], plugin["plugin_root"], plugin["enabled"]]
    for plugin in registry["result"]["plugins"]
)
assert registered == [
    ["annotate", str(annotate), True],
    ["annotate-links", str(links), True],
], registered

fixture = Path.cwd() / "plugin with spaces"
(fixture / "bin").mkdir(parents=True)
log = Path.cwd() / "handoff.json"
recorder = fixture / "bin/plannotator-tui.exe"
recorder.write_text(
    f"#!{sys.executable}\n"
    "import json, os, sys\n"
    "from pathlib import Path\n"
    f"Path({str(log)!r}).write_text(json.dumps({{\n"
    "    'args': sys.argv[1:], 'cwd': os.getcwd(),\n"
    "    'id': os.environ['HERDR_PLUGIN_ID'],\n"
    "    'root': os.environ['HERDR_PLUGIN_ROOT'],\n"
    "    'context': os.environ['HERDR_PLUGIN_CONTEXT_JSON'],\n"
    "}))\n"
)
recorder.chmod(0o755)
fake_herdr = Path.cwd() / "herdr"
fake_herdr.write_text(
    f"#!{sys.executable}\n"
    "import json, sys\n"
    "assert sys.argv[1:] == ['plugin', 'list', '--plugin', 'annotate', '--json']\n"
    f"print(json.dumps({{'plugin_root': {str(fixture)!r}, 'enabled': True}}, separators=(',', ':')))\n"
)
fake_herdr.chmod(0o755)
context = json.dumps({"url": "file:///project/plan.md", "pane_id": "w1:p1"})
link_manifest = tomllib.loads((links / "herdr-plugin.toml").read_text())
assert link_manifest["link_handlers"][0] == {
    "id": "markdown-file",
    "title": "Annotate this file",
    "pattern": r"^file://.*\.(md|markdown|mdx)$",
    "action": "open-link",
    "platforms": ["macos", "linux"],
}
action = next(action for action in link_manifest["actions"] if action["id"] == "open-link")
run(
    *action["command"],
    cwd=home,
    env=dict(
        env,
        PATH="",
        HERDR_BIN_PATH=str(fake_herdr),
        HERDR_PLUGIN_ID="annotate-links",
        HERDR_PLUGIN_ROOT=str(links),
        HERDR_PLUGIN_CONTEXT_JSON=context,
    ),
)
handoff = json.loads(log.read_text())
assert handoff == {
    "args": ["herdr", "open"],
    "cwd": str(fixture),
    "id": "annotate",
    "root": str(fixture),
    "context": context,
}, handoff
print("PASS: Annotate binaries, plugin registration and Markdown link handoff")
