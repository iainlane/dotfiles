# shellcheck shell=bash

set -euo pipefail

updater="$1"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/bin" "${fixture}/pkgs/herdr-disp-model" "${fixture}/pkgs/build-support" "${fixture}/source"
cp "$2" "${fixture}/pkgs/build-support/replace-once.jq"
export UPDATE_TEST_ROOT="${fixture}"
export UPDATE_TEST_VERSION=0.3.0
export PATH="${fixture}/bin:${PATH}"

for command in git nix nix-update; do
	printf '#!%s\n' "${BASH}" >"${fixture}/bin/${command}"
done
cat >>"${fixture}/bin/git" <<'SH'
printf '%s\n' "${UPDATE_TEST_ROOT}"
SH
cat >>"${fixture}/bin/nix-update" <<'SH'
printf 'version = "0-unstable-2026-09-19";\nrev = "new-revision";\nhash = "new-hash";\n' >pkgs/herdr-disp-model/package.nix
if [[ "${UPDATE_TEST_FAIL:-}" == update ]]; then exit 1; fi
SH
cat >>"${fixture}/bin/nix" <<'SH'
set -euo pipefail
case "$*" in
"build --no-link --print-out-paths .#herdr-disp-model.src")
  if [[ "${UPDATE_TEST_FAIL:-}" == source ]]; then exit 1; fi
  printf '%s/source\n' "${UPDATE_TEST_ROOT}"
  ;;
*herdr-disp-model.version) printf '0-unstable-2026-09-19\n' ;;
*fromTOML*)
  if [[ "${UPDATE_TEST_FAIL:-}" == manifest ]]; then exit 1; fi
  printf '%s\n' "${UPDATE_TEST_VERSION}"
  ;;
*) exit 1 ;;
esac
SH
chmod +x "${fixture}/bin/"*
cd "${fixture}/pkgs/herdr-disp-model"
printf 'version = "0.3.0-unstable-2026-09-19";\nrev = "old-revision";\nhash = "old-hash";\n' >original.nix

for version in 0.3.0 0.4.0; do
	cp original.nix package.nix
	UPDATE_TEST_VERSION="${version}" bash "${updater}"
	printf 'version = "%s-unstable-2026-09-19";\nrev = "new-revision";\nhash = "new-hash";\n' "${version}" >expected.nix
	diff -u expected.nix package.nix
done

for failure in update source manifest; do
	cp original.nix package.nix
	if UPDATE_TEST_FAIL="${failure}" bash "${updater}"; then
		echo "The failed ${failure} unexpectedly succeeded." >&2
		exit 1
	fi
	cmp original.nix package.nix
done
