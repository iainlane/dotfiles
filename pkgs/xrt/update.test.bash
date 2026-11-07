# shellcheck shell=bash

set -euo pipefail

updater="$1"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/bin" "${fixture}/pkgs/xrt"
export UPDATE_TEST_ROOT="${fixture}"
export PATH="${fixture}/bin:${PATH}"

for command in git gh nix nix-update; do
	printf '#!%s\n' "${BASH}" >"${fixture}/bin/${command}"
done
cat >>"${fixture}/bin/git" <<'SH'
printf '%s\n' "${UPDATE_TEST_ROOT}"
SH
cat >>"${fixture}/bin/gh" <<'SH'
set -euo pipefail
case "$2" in
repos/amd/xdna-driver/tags) printf '%s\n' '[{"name":"2.9.1"},{"name":"2.10.2"},{"name":"topic"}]' ;;
repos/Xilinx/XRT/git/ref/tags/2.10.2) printf '{}\n' ;;
*) exit 1 ;;
esac
SH
cat >>"${fixture}/bin/nix" <<'SH'
printf '%s\n' "${UPDATE_TEST_CURRENT:-2.9.1}"
SH
cat >>"${fixture}/bin/nix-update" <<'SH'
set -euo pipefail
printf '%s\n' "${!#}" >>"${UPDATE_TEST_ROOT}/calls"
python3 - "$@" <<'PY'
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--override-filename', required=True)
parser.add_argument('--version', required=True)
parser.add_argument('--no-src', action='store_true')
options, rest = parser.parse_known_args()
package = Path(options.override_filename)
data = json.loads(package.read_text())
if rest[-1] == 'xrt':
    if options.version != 'skip':
        data['version'] = options.version
    source_hash = 'new-xrt'
else:
    source_hash = 'new-xdna'
if not options.no_src:
    data['hash'] = source_hash
package.write_text(json.dumps(data) + '\n')
PY
if [[ "${!#}" == xrt.xdna.plugin && "${UPDATE_TEST_FAIL:-0}" == 1 ]]; then exit 2; fi
SH
chmod +x "${fixture}/bin/"*
cd "${fixture}/pkgs/xrt"

reset_fixture() {
	printf '{"version":"2.9.1","hash":"old-xrt"}\n' >package.nix
	printf '{"hash":"old-xdna"}\n' >xdna.nix
}

reset_fixture
UPDATE_TEST_CURRENT=2.10.2 bash "${updater}"
test ! -e "${fixture}/calls"
UPDATE_TEST_CURRENT=2.10.2 bash "${updater}" --force
test -e "${fixture}/calls"

reset_fixture
bash "${updater}"
python3 - <<'PY'
import json
from pathlib import Path

assert {path: json.loads(Path(path).read_text()) for path in ['package.nix', 'xdna.nix']} == {
    'package.nix': {'version': '2.10.2', 'hash': 'new-xrt'},
    'xdna.nix': {'hash': 'new-xdna'},
}
PY

reset_fixture
cp package.nix "${fixture}/original-xrt"
cp xdna.nix "${fixture}/original-xdna"
if UPDATE_TEST_FAIL=1 bash "${updater}"; then
	echo 'The failed XDNA update unexpectedly succeeded.' >&2
	exit 1
fi
cmp package.nix "${fixture}/original-xrt"
cmp xdna.nix "${fixture}/original-xdna"
