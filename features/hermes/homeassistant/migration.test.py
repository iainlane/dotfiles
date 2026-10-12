import errno
import json
import os
import sys
from pathlib import Path
from unittest.mock import patch

package = Path(sys.argv[1])
os.environ.update(json.loads((package / "command-map.json").read_text())["env"])

from gateway.platform_registry import platform_registry
from hermes_cli.left_core_migration import migrate_home
from hermes_cli.plugins import discover_plugins, get_plugin_manager
from tools.registry import registry


def refuse_install(name: str) -> dict:
    raise AssertionError(f"Managed plugin {name} must already be installed")


home = Path(os.environ["HERMES_HOME"])
before = (home / "config.yaml").read_bytes()
managed_file = Path(os.environ["HERMES_MANAGED_DIR"]) / "config.yaml"
managed_before = managed_file.read_bytes()
notices: list[str] = []

with patch(
    "hermes_cli.config.atomic_config_write",
    side_effect=OSError(errno.EROFS, "Read-only file system"),
) as write:
    installed = migrate_home(
        home, install=refuse_install, say=notices.append, process_env=True
    )

assert (installed, notices, write.call_count) == ([], [], 0), (
    installed,
    notices,
    write.call_count,
)
assert (home / "config.yaml").read_bytes() == before
assert managed_file.read_bytes() == managed_before

discover_plugins()
plugins = {plugin["name"]: plugin for plugin in get_plugin_manager().list_plugins()}
plugin = plugins["homeassistant"]
entry = platform_registry.get("homeassistant")

status = (plugin["enabled"], plugin["error"], entry.name if entry else None)
assert status == (
    True,
    None,
    "homeassistant",
), status
assert sorted(registry.get_tool_names_for_toolset("homeassistant")) == [
    "ha_call_service",
    "ha_get_state",
    "ha_list_entities",
    "ha_list_services",
]
print("PASS: managed Home Assistant plugin loads without migration writes or notices")
