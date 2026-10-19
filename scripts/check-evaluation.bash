#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
evaluation_config="$(<"${script_dir}/../lib/nix/evaluation.conf")"
export NIX_CONFIG="${NIX_CONFIG:-}"$'\n'"${evaluation_config}"

if [[ "$#" -eq 0 ]]; then
	set -- --raw .#cupboardOutputs --apply \
		'targets: builtins.deepSeq (map (target: target.rootDrvPath) targets) "Evaluation passed.\n"'
fi

exec nix eval "$@" --option allow-import-from-derivation false
