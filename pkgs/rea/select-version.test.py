import json
import os
import sys
from dataclasses import asdict
from pathlib import Path
from unittest.mock import patch
from urllib.parse import urlparse

module_root = Path(os.environ["UPDATE_TEST_NIX_UPDATE"])
sys.path.insert(0, str(next(module_root.glob("lib/python*/site-packages"))))

from nix_update.version import VersionFetchConfig, fetch_latest_version
from nix_update.version.version import Version, VersionPreference

arguments = sys.argv[1:]
preference = next(
    argument.split("=", 1)[1]
    for argument in arguments
    if argument.startswith("--version=")
)
assert preference == "stable", f"Expected stable releases, received {preference}"
assert "--use-github-releases" in arguments
expression = next(
    argument.split("=", 1)[1]
    for argument in arguments
    if argument.startswith("--version-regex=")
)
version = os.environ["UPDATE_TEST_VERSION"]
releases = [
    {
        "tag_name": "experiment/atomic-codemode-wait-runtime-20261016",
        "prerelease": False,
    },
    {"tag_name": "rea-agents-99.0.0-rc.1", "prerelease": True},
    {"tag_name": "rea-agents-99.0.0", "prerelease": True},
    {"tag_name": "unrelated-100.0.0", "prerelease": False},
    {"tag_name": "rea-agents-" + version, "prerelease": False},
    {"tag_name": "rea-agents-6.6.0", "prerelease": False},
]
config = VersionFetchConfig(
    preference=VersionPreference.from_str(preference),
    version_regex=expression,
    fetcher_args={"use_github_releases": True},
)
with (
    patch("urllib.request.urlopen", side_effect=AssertionError("Unexpected network request")),
    patch(
        "nix_update.version.github._dorequest",
        return_value=json.dumps(releases).encode(),
    ),
):
    selected = fetch_latest_version(urlparse("https://github.com/morluto/rea"), config)
assert selected == Version(version, prerelease=False, rev="rea-agents-" + version)
Path(os.environ["UPDATE_TEST_ROOT"], "selected.json").write_text(
    json.dumps(asdict(selected))
)
