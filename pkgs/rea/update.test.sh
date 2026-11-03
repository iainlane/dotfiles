# shellcheck shell=bash

set -euo pipefail

updater="$1"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/bin" "${fixture}/pkgs/rea"
export UPDATE_TEST_ROOT="${fixture}"
export UPDATE_TEST_NIX_UPDATE="$2"
export PATH="${fixture}/bin:${PATH}"

cat >"${fixture}/select-version.py" <<'PY'
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
    ) as request,
):
    selected = fetch_latest_version(urlparse("https://github.com/morluto/rea"), config)
assert selected == Version(version, prerelease=False, rev="rea-agents-" + version)
assert [call.args[1] for call in request.call_args_list] == [
    "https://api.github.com/repos/morluto/rea/releases?per_page=100&page=1"
]
Path(os.environ["UPDATE_TEST_ROOT"], "selected.json").write_text(
    json.dumps(asdict(selected))
)
PY

for command in git nix-update; do
	printf '#!%s\n' "${BASH}" >"${fixture}/bin/${command}"
done
cat >>"${fixture}/bin/git" <<'SH'
printf '%s\n' "${UPDATE_TEST_ROOT}"
SH
cat >>"${fixture}/bin/nix-update" <<'SH'
set -euo pipefail
python3 "${UPDATE_TEST_ROOT}/select-version.py" "$@"
version="$(jq --raw-output .number "${UPDATE_TEST_ROOT}/selected.json")"
revision="$(jq --raw-output .rev "${UPDATE_TEST_ROOT}/selected.json")"
printf 'version = "%s";\nrev = "%s";\nhash = "new-hash";\nnpmDepsHash = "new-deps";\n' "${version}" "${revision}" >pkgs/rea/package.nix
if [[ "${UPDATE_TEST_FAIL:-}" == update ]]; then exit 1; fi
SH
chmod +x "${fixture}/bin/"*
cd "${fixture}/pkgs/rea"
printf 'version = "6.7.0-unstable-2026-10-24";\nrev = "old-revision";\nhash = "old-hash";\nnpmDepsHash = "old-deps";\n' >original.nix

for version in 6.8.0 6.9.0; do
	cp original.nix package.nix
	UPDATE_TEST_VERSION="${version}" bash "${updater}"
	printf 'version = "%s";\nrev = "rea-agents-%s";\nhash = "new-hash";\nnpmDepsHash = "new-deps";\n' "${version}" "${version}" >expected.nix

	diff -u expected.nix package.nix
done

cp original.nix package.nix
if UPDATE_TEST_VERSION=6.8.0 UPDATE_TEST_FAIL=update bash "${updater}"; then
	echo "The failed update unexpectedly succeeded." >&2
	exit 1
fi
cmp original.nix package.nix
