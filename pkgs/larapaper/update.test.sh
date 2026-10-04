# shellcheck shell=bash

set -euo pipefail

updater="$1"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

mkdir -p "${fixture}/bin" "${fixture}/pkgs/larapaper"
cat >"${fixture}/original.nix" <<'NIX'
{
  version = "0.43.1";
  rev = "f849ce24562bcc218fdc43246c9410f78b71ce91";
  hash = "sha256-QK6EWpxrp36aSoaF4wECUNcUVnrp3ZaZ7Vn2IB84Ae4=";
  vendorHash = "sha256-O+bl2HWV6f0G+91LTOvh0pDYissx6zSZ295ODXJR4FA=";
  npmDepsHash = "sha256-pMQHgRsALtNyo0dYdcVlhJMn4J8y48hqF+pFkz516p0=";
  patches = [ "https://example.com/pinned-assets.patch" "https://example.com/pinned-fonts.patch" ];
}
NIX
cp "${fixture}/original.nix" "${fixture}/pkgs/larapaper/package.nix"
export PATH="${fixture}/bin:${PATH}"
export UPDATE_TEST_ROOT="${fixture}"
export UPDATE_TEST_VERSION="0.44.0"
export UPDATE_TEST_FAIL=0

cat >"${fixture}/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${UPDATE_TEST_ROOT}"
SH

cat >"${fixture}/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
repos/usetrmnl/larapaper/releases/latest) printf '%s\n' "${UPDATE_TEST_VERSION}" ;;
repos/usetrmnl/larapaper/commits/*) printf '%040d\n' 1 ;;
*) exit 1 ;;
esac
SH

cat >"${fixture}/bin/nix" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
eval) printf '%s\n' '{"version":"0.43.1","rev":"f849ce24562bcc218fdc43246c9410f78b71ce91","hash":"sha256-QK6EWpxrp36aSoaF4wECUNcUVnrp3ZaZ7Vn2IB84Ae4="}' ;;
flake) printf '%s\n' '{"hash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}' ;;
*) exit 1 ;;
esac
SH

cat >"${fixture}/bin/nix-update" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${UPDATE_TEST_ROOT}/arguments"
if [[ "${UPDATE_TEST_FAIL}" == 1 ]]; then
  printf 'partial update\n' >pkgs/larapaper/package.nix
  exit 2
fi
python3 - <<'PY'
from pathlib import Path

package = Path('pkgs/larapaper/package.nix')
text = package.read_text()
text = text.replace('sha256-O+bl2HWV6f0G+91LTOvh0pDYissx6zSZ295ODXJR4FA=', 'sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=')
text = text.replace('sha256-pMQHgRsALtNyo0dYdcVlhJMn4J8y48hqF+pFkz516p0=', 'sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=')
package.write_text(text)
PY
SH

chmod +x "${fixture}/bin/"*
cd "${fixture}/pkgs/larapaper"

UPDATE_TEST_VERSION=0.43.1 bash -euo pipefail "${updater}"
cmp package.nix "${fixture}/original.nix"
test ! -e "${fixture}/arguments"

bash -euo pipefail "${updater}"
python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ['UPDATE_TEST_ROOT'])
expected = (root / 'original.nix').read_text()
for before, after in [
    ('"0.43.1"', '"0.44.0"'),
    ('f849ce24562bcc218fdc43246c9410f78b71ce91', '0000000000000000000000000000000000000001'),
    ('sha256-QK6EWpxrp36aSoaF4wECUNcUVnrp3ZaZ7Vn2IB84Ae4=', 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='),
    ('sha256-O+bl2HWV6f0G+91LTOvh0pDYissx6zSZ295ODXJR4FA=', 'sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='),
    ('sha256-pMQHgRsALtNyo0dYdcVlhJMn4J8y48hqF+pFkz516p0=', 'sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC='),
]:
    expected = expected.replace(before, after)
assert (root / 'pkgs/larapaper/package.nix').read_text() == expected
assert (root / 'arguments').read_text().splitlines() == [
    '--flake', '--system', 'aarch64-linux', '--version=skip', '--no-src',
    '--subpackage', 'frontend', '--override-filename', 'pkgs/larapaper/package.nix',
    'larapaper',
]
PY

cp "${fixture}/original.nix" package.nix
if UPDATE_TEST_FAIL=1 bash -euo pipefail "${updater}"; then
	echo 'The failed dependency update unexpectedly succeeded.' >&2
	exit 1
fi
cmp package.nix "${fixture}/original.nix"

rm "${fixture}/arguments"
cp "${fixture}/original.nix" package.nix
UPDATE_TEST_VERSION=0.43.1 bash -euo pipefail "${updater}" --force
test -e "${fixture}/arguments"
