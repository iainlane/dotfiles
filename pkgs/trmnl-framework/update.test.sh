# shellcheck shell=bash

set -euo pipefail

updater="$1"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/bin"
export PATH="${fixture}/bin:${PATH}"
export FRAMEWORK_TEST_TAG=v3.5.0
export FRAMEWORK_TEST_FAIL=0

cat >"${fixture}/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FRAMEWORK_TEST_TAG}"
SH
cat >"${fixture}/bin/nix" <<'SH'
#!/usr/bin/env bash
if [[ "${FRAMEWORK_TEST_FAIL}" == 1 ]]; then exit 1; fi
printf '%s\n' '{"hash":"new-release"}'
SH
chmod +x "${fixture}/bin/"*
cd "${fixture}"
printf '%s\n' '{"version":"3.4.0","hash":"current-release","legacy":[{"version":"3.3.2","hash":"older-release"}]}' >source.json
cp source.json original.json

FRAMEWORK_TEST_TAG=v3.4.0 bash "${updater}"
cmp source.json original.json

bash "${updater}"
printf '%s\n' '{"version":"3.5.0","hash":"new-release","legacy":[{"version":"3.3.2","hash":"older-release"},{"version":"3.4.0","hash":"current-release"}]}' >expected.json
diff -u <(jq -S . expected.json) <(jq -S . source.json)

cp source.json updated.json
bash "${updater}" --force
cmp source.json updated.json

cp original.json source.json
if FRAMEWORK_TEST_FAIL=1 bash "${updater}"; then
	echo 'The failed release fetch unexpectedly succeeded.' >&2
	exit 1
fi
cmp source.json original.json
