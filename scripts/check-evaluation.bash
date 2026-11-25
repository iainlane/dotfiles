#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
evaluation_config="$(<"${script_dir}/../lib/nix/evaluation.conf")"
export NIX_CONFIG="${NIX_CONFIG:-}"$'\n'"${evaluation_config}"

if [[ "$#" -gt 0 && ! ("$#" -eq 1 && "$1" == --manifest) ]]; then
	exec nix eval "$@" --option allow-import-from-derivation false
fi

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

shard_expression="$(<"${script_dir}/evaluation-shards.nix")"
evaluate_shard() {
	nix eval --raw .#.cupboardOutputs \
		--apply "(${shard_expression}) { shard = $1; }" \
		--option allow-import-from-derivation false
}

evaluate_shard null >"${scratch}/inventory"
if [[ ! -s "${scratch}/inventory" ]]; then
	printf 'The evaluation inventory is empty.\n' >&2
	exit 1
fi

cut -f 2 "${scratch}/inventory" | LC_ALL=C sort | uniq -d >"${scratch}/duplicates"
if [[ -s "${scratch}/duplicates" ]]; then
	printf 'The evaluation inventory contains duplicate targets:\n' >&2
	cat "${scratch}/duplicates" >&2
	exit 1
fi

cut -f 1 "${scratch}/inventory" | uniq >"${scratch}/shards"
while IFS= read -r shard; do
	if [[ ! "${shard}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
		printf 'Invalid evaluation shard: %s\n' "${shard}" >&2
		exit 1
	fi

	evaluate_shard "\"${shard}\"" || {
		status=$?
		printf 'Evaluation shard failed: %s\n' "${shard}" >&2
		exit "${status}"
	}
done <"${scratch}/shards" >"${scratch}/manifest"

cut -f 1,2 "${scratch}/manifest" >"${scratch}/evaluated"
if [[ "$(<"${scratch}/evaluated")" != "$(<"${scratch}/inventory")" ]]; then
	printf 'The evaluated targets differ from the evaluation inventory.\n' >&2
	exit 1
fi

if [[ "$#" -eq 0 ]]; then
	printf 'Evaluation passed.\n'
	exit 0
fi

cut -f 2,3 "${scratch}/manifest"
