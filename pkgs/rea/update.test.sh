# shellcheck shell=bash

set -euo pipefail

updater="$1"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/bin" "${fixture}/pkgs/rea"
export UPDATE_TEST_ROOT="${fixture}"
export UPDATE_TEST_NIX_UPDATE="$2"
export UPDATE_TEST_SELECTOR="$3"
export PATH="${fixture}/bin:${PATH}"

for command in git nix-update; do
	printf '#!%s\n' "${BASH}" >"${fixture}/bin/${command}"
done
cat >>"${fixture}/bin/git" <<'SH'
printf '%s\n' "${UPDATE_TEST_ROOT}"
SH
cat >>"${fixture}/bin/nix-update" <<'SH'
set -euo pipefail
python3 "${UPDATE_TEST_SELECTOR}" "$@"
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
