#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
evaluation_config="$(<"${script_dir}/../lib/nix/evaluation.conf")"
export NIX_CONFIG="${NIX_CONFIG:-}"$'\n'"${evaluation_config}"

if [[ "$#" -eq 0 ]]; then
	set -- --raw .#.cupboardOutputs --apply \
		'targets: builtins.deepSeq (map (target: target.rootDrvPath) targets) "Evaluation passed.\n"'
fi

if [[ -n ${FLAKE_UPDATE_PROFILE_DIR:-} ]]; then
	profile=$(mktemp -d "${FLAKE_UPDATE_PROFILE_DIR}/gate.XXXXXX")
	export NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="${profile}/stats.json"
	set -- "$@" --option eval-profiler flamegraph \
		--option eval-profile-file "${profile}/stacks.folded" \
		--option eval-profiler-frequency 49
fi

exec nix eval "$@" --option allow-import-from-derivation false
