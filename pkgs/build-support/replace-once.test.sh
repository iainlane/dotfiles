# shellcheck shell=bash

set -euo pipefail

program="$1"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

replace() {
	jq --raw-input --slurp --join-output \
		--arg old 'github:owner/repo/v1.8.0' \
		--arg new 'github:owner/repo/v1.9.0' \
		--from-file "${program}" "$1"
}

printf '%s\n' '{' '  url = "github:owner/repo/v1.8.0";' '  other = "github:owner/other/v1.8.0";' '}' >"${fixture}/one"
printf '%s\n' '{' '  url = "github:owner/repo/v1.9.0";' '  other = "github:owner/other/v1.8.0";' '}' >"${fixture}/expected"
replace "${fixture}/one" >"${fixture}/replaced"
cmp "${fixture}/expected" "${fixture}/replaced"

printf '%s\n' 'url = "github:owner/repo/v1x8x0";' >"${fixture}/none"
printf '%s\n' 'a = "github:owner/repo/v1.8.0";' 'b = "github:owner/repo/v1.8.0";' >"${fixture}/two"

for name in none two; do
	if replace "${fixture}/${name}" >/dev/null 2>&1; then
		echo "The replacement unexpectedly succeeded for the '${name}' fixture." >&2
		exit 1
	fi
done
