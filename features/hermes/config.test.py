import os
import subprocess
import sys
from pathlib import Path

from hermes_cli.config import load_config, save_config, set_config_value
from hermes_cli.left_core_migration import migrate_home
from utils import fast_safe_load

home = Path(os.environ["HERMES_HOME"])
assert (home / "config.yaml").stat().st_mode & 0o777 == 0o600
managed_file = Path(os.environ["HERMES_MANAGED_DIR"]) / "config.yaml"
managed_before = managed_file.read_bytes()

runtime = {
    "model": {"default": "runtime/model"},
    "plugins": {"enabled": ["runtime-plugin"]},
    "command_allowlist": ["git status"],
    "display": {"show_reasoning": True},
}
save_config(runtime, strip_defaults=False)
assert fast_safe_load((home / "config.yaml").read_text()) == {
    "model": {},
    "plugins": {},
    "command_allowlist": ["git status"],
    "display": {"show_reasoning": True},
}

try:
    set_config_value("model.default", "override/model")
except SystemExit as error:
    assert error.code == 1
else:
    raise AssertionError("Hermes accepted a change to the managed model")

config = load_config()
assert {
    "model.default": config["model"]["default"],
    "plugins.enabled": config["plugins"]["enabled"],
    "command_allowlist": config["command_allowlist"],
    "display.show_reasoning": config["display"]["show_reasoning"],
} == {
    "model.default": "nix/model",
    "plugins.enabled": ["homeassistant"],
    "command_allowlist": ["git status"],
    "display.show_reasoning": True,
}


def refuse_install(name: str) -> dict:
    raise AssertionError(f"Managed plugin {name} must already be installed")


notices: list[str] = []
migration = (
    migrate_home(home, install=refuse_install, say=notices.append, process_env=True),
    notices,
)
assert migration == ([], []), migration

restart_check = """
from hermes_cli.config import load_config
from gateway.config_loader import read_yaml_layers
from hermes_constants import get_hermes_home

expected = {
    '_left_core_installed': ['homeassistant'],
    '_left_core_scoped': ['homeassistant'],
    'model': {'default': 'nix/model'},
    'plugins': {'enabled': ['homeassistant']},
    'command_allowlist': ['git status'],
    'display': {'show_reasoning': True},
}
assert read_yaml_layers(get_hermes_home()) == expected
assert load_config()['command_allowlist'] == ['git status']
"""
subprocess.run([sys.executable, "-c", restart_check], check=True)
assert managed_file.read_bytes() == managed_before
print("PASS: runtime config persists and managed settings take precedence")
