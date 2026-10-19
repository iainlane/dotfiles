# shellcheck shell=bash

set -euo pipefail

updater="$1"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/bin" "${fixture}/pkgs/fastflowlm/tokenizers-cpp" "${fixture}/source/rust"
export UPDATE_TEST_ROOT="${fixture}"
export UPDATE_TEST_VERSION=1.2.3
export PATH="${fixture}/bin:${PATH}"

for command in git gh nix nix-update cargo; do
	printf '#!%s\n' "${BASH}" >"${fixture}/bin/${command}"
done
cat >>"${fixture}/bin/git" <<'SH'
printf '%s\n' "${UPDATE_TEST_ROOT}"
SH
cat >>"${fixture}/bin/gh" <<'SH'
set -euo pipefail
case "$2" in
repos/ROCm/FastFlowLM/releases/latest) printf 'v%s\n' "${UPDATE_TEST_VERSION}" ;;
repos/ROCm/FastFlowLM/contents/third_party/tokenizers-cpp?ref=v*) printf '%040d\n' 1 ;;
repos/mlc-ai/tokenizers-cpp/commits/*) printf '2026-03-01\n' ;;
*) exit 1 ;;
esac
SH
cat >>"${fixture}/bin/nix" <<'SH'
set -euo pipefail
case "$1" in
eval) printf '{"version":"1.0.7","sourceHash":"old-source-hash","tokenizersVersion":"0.1.1-unstable-2026-02-20","rev":"old-revision","hash":"old-hash"}\n' ;;
flake)
  case "$4" in
  github:ROCm/FastFlowLM/v*)
    if [[ "${UPDATE_TEST_FAIL:-}" == prefetch ]]; then exit 2; fi
    touch "${UPDATE_TEST_ROOT}/called"
    printf '{"hash":"new-source-hash"}\n'
    ;;
  github:mlc-ai/tokenizers-cpp/*) printf '{"hash":"new-hash","storePath":"%s/source"}\n' "${UPDATE_TEST_ROOT}" ;;
  *) exit 1 ;;
  esac
  ;;
*) exit 1 ;;
esac
SH
cat >>"${fixture}/bin/nix-update" <<'SH'
echo 'Source hashing must not build target-system derivations.' >&2
exit 1
SH
cat >>"${fixture}/bin/cargo" <<'SH'
set -euo pipefail
printf 'new lock\n' >Cargo.lock
if [[ "${UPDATE_TEST_FAIL:-}" == cargo ]]; then exit 2; fi
SH
chmod +x "${fixture}/bin/"*
cd "${fixture}/pkgs/fastflowlm"

reset_fixture() {
	printf 'version = "1.0.7";\nhash = "old-source-hash";\n' >package.nix
	printf 'version = "0.1.1-unstable-2026-02-20";\nrev = "old-revision";\nhash = "old-hash";\n' >tokenizers-cpp/default.nix
	printf 'old lock\n' >tokenizers-cpp/Cargo.lock
}

reset_fixture
UPDATE_TEST_VERSION=1.0.7 bash "${updater}"
test ! -e "${fixture}/called"

reset_fixture
bash "${updater}"
python3 - <<'PY'
import re
from pathlib import Path

def declarations(path):
    return dict(re.findall(r'(\w+) = "([^"]+)";', Path(path).read_text()))

assert {
    'release': declarations('package.nix'),
    'tokenizers': declarations('tokenizers-cpp/default.nix'),
    'lock': Path('tokenizers-cpp/Cargo.lock').read_text(),
} == {
    'release': {'version': '1.2.3', 'hash': 'new-source-hash'},
    'tokenizers': {
        'version': '0.1.1-unstable-2026-03-01',
        'rev': '0000000000000000000000000000000000000001',
        'hash': 'new-hash',
    },
    'lock': 'new lock\n',
}
PY

for failure in cargo prefetch tokenizer; do
	reset_fixture
	if [[ "${failure}" == tokenizer ]]; then
		printf 'hash = "old-hash";\n' >>tokenizers-cpp/default.nix
	fi
	rm -rf "${fixture}/original"
	cp -r . "${fixture}/original"
	if UPDATE_TEST_FAIL="${failure}" bash "${updater}"; then
		echo "The failed ${failure} update unexpectedly succeeded." >&2
		exit 1
	fi
	diff -r . "${fixture}/original"
done

reset_fixture
UPDATE_TEST_VERSION=1.0.7 bash "${updater}" --force
python3 - <<'PY'
from pathlib import Path

assert Path('package.nix').read_text() == 'version = "1.0.7";\nhash = "new-source-hash";\n'
PY
