# shellcheck shell=bash

set -euo pipefail

updater="$1"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

export FIXTURE="${fixture}"
export LOCAL_PACKAGES_ATTR="${LOCAL_PACKAGES_ATTR:-legacyPackages.fixture.localPackages}"
mkdir -p "${fixture}/pkgs/pi-diff/npm-deps" "${fixture}/upstream"

git() {
	[[ "$*" == 'rev-parse --show-toplevel' ]]
	printf '%s\n' "${FIXTURE}"
}

nix() {
	[[ "${PWD}" == "${FIXTURE}" ]]
	case "$*" in
	"eval --raw .#${LOCAL_PACKAGES_ATTR}.pi.version --option allow-import-from-derivation false")
		printf '1.6.1'
		;;
	"build --no-link --print-out-paths .#${LOCAL_PACKAGES_ATTR}.pi-diff.src")
		printf '%s\n' "${FIXTURE}/upstream"
		;;
	*) return 1 ;;
	esac
}

nix-update() {
	[[ "${PWD}" == "${FIXTURE}" ]]
	case "$*" in
	"--flake --override-filename pkgs/pi-diff/package.nix --version=branch=pi-integration-fixes ${LOCAL_PACKAGES_ATTR}.pi-diff")
		touch "${FIXTURE}/source-updated"
		;;
	"--flake --override-filename pkgs/pi-diff/package.nix --version=skip --no-src ${LOCAL_PACKAGES_ATTR}.pi-diff")
		;;
	*) return 1 ;;
	esac
}

npm() {
	case "$*" in
	"view @earendil-works/pi-coding-agent@1.6.1 dependencies --json")
		printf '%s\n' '{"@earendil-works/pi-ai":"1.6.2","@earendil-works/pi-tui":"1.6.3"}'
		;;
	"install --package-lock-only --ignore-scripts --no-audit --no-fund --save-dev --save-exact @earendil-works/pi-coding-agent@1.6.1 @earendil-works/pi-ai@1.6.2 @earendil-works/pi-tui@1.6.3")
		[[ "${FAIL_NPM:-}" != 1 ]] || return 1
		diff -u <(jq -S '.packages[""]' package-lock.json) <(jq -S . package.json)
		jq '.packages[""].devDependencies += {
			"@earendil-works/pi-coding-agent": "1.6.1",
			"@earendil-works/pi-ai": "1.6.2",
			"@earendil-works/pi-tui": "1.6.3"
		}' package-lock.json >new-lock.json
		mv new-lock.json package-lock.json
		;;
	*) return 1 ;;
	esac
}

export -f git nix nix-update npm

cd "${fixture}/pkgs/pi-diff"
lock=npm-deps/package-lock.json
printf '%s\n' '{"packages":{"":{"version":"0.9.3","devDependencies":{"@earendil-works/pi-coding-agent":"1.6.0","@earendil-works/pi-ai":"1.6.0","@earendil-works/pi-tui":"1.6.0"}},"node_modules/diff":{"version":"8.0.4"}}}' >"${lock}"
jq '.packages[""].version = "0.9.4" | .packages["node_modules/diff"].version = "8.0.5"' "${lock}" >"${fixture}/upstream/package-lock.json"

printf '%s\n' '{"packages":{"":{"version":"0.9.3","devDependencies":{"@earendil-works/pi-coding-agent":"1.6.1","@earendil-works/pi-ai":"1.6.2","@earendil-works/pi-tui":"1.6.3"}},"node_modules/diff":{"version":"8.0.4"}}}' >expected-refresh.json
printf '%s\n' '{"packages":{"":{"version":"0.9.4","devDependencies":{"@earendil-works/pi-coding-agent":"1.6.1","@earendil-works/pi-ai":"1.6.2","@earendil-works/pi-tui":"1.6.3"}},"node_modules/diff":{"version":"8.0.5"}}}' >expected-update.json

bash "${updater}" --refresh
diff -u <(jq -S . expected-refresh.json) <(jq -S . "${lock}")
[[ ! -e "${fixture}/source-updated" ]]

bash "${updater}"
diff -u <(jq -S . expected-update.json) <(jq -S . "${lock}")
[[ -e "${fixture}/source-updated" ]]

cp "${lock}" before-failure.json
if FAIL_NPM=1 bash "${updater}" --refresh; then
	printf 'Refresh succeeded after npm failed.\n' >&2
	exit 1
fi
cmp before-failure.json "${lock}"
