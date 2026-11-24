set -euo pipefail

samples=$1
strategy=$2
scratch=$(mktemp -d "$RUNNER_TEMP/evaluation.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

measure() {
	local phase=$1 output=$2 expression=$3
	printf '%s\t%s\n' "$EPOCHREALTIME" "$phase" >>"$samples/phases.tsv"
	command time --append --output "$samples/evaluation.tsv" \
		--format "$phase\t%e\t%U\t%S\t%M\t%x" \
		bash scripts/check-evaluation.bash --json .#.cupboardOutputs \
		--apply "$expression" >"$output"
}

nix --version | tee "$samples/evaluator.txt"
printf 'phase\twall_s\tuser_s\tsystem_s\tmax_rss_KiB\texit_status\n' >"$samples/evaluation.tsv"
measure inventory "$scratch/inventory.json" \
	'targets: map (target: { inherit (target) system cohort rootSuffix; }) targets'

projection='map (target: { inherit (target) rootSuffix rootDrvPath; })'
case $strategy in
full)
	measure full "$scratch/result.json" "targets: $projection targets"
	;;
full-gc)
	GC_FREE_SPACE_DIVISOR=8 measure full-gc "$scratch/result.json" "targets: $projection targets"
	;;
system | cohort)
	jq -r --arg field "$strategy" 'map(.[$field]) | unique[]' "$scratch/inventory.json" >"$scratch/groups.txt"
	parts=()
	while IFS= read -r group; do
		if [[ ! $group =~ ^(aarch64|x86_64)-(darwin|linux)(-deploy)?$ ]]; then
			printf 'Unexpected %s: %s\n' "$strategy" "$group" >&2
			exit 1
		fi
		part="$scratch/$group.json"
		measure "$group" "$part" \
			"targets: $projection (builtins.filter (target: target.$strategy == \"$group\") targets)"
		parts+=("$part")
	done <"$scratch/groups.txt"
	jq -s 'add' "${parts[@]}" >"$scratch/result.json"
	;;
*)
	printf 'Unknown evaluation strategy: %s\n' "$strategy" >&2
	exit 2
	;;
esac

jq -e --slurpfile inventory "$scratch/inventory.json" '
	(map(.rootSuffix) | sort) as $actual
	| ($inventory[0] | map(.rootSuffix) | sort) as $expected
	| $actual == $expected and $actual == ($actual | unique)
' "$scratch/result.json" >/dev/null

jq -cS 'sort_by(.rootSuffix)' "$scratch/result.json" |
	sha256sum | cut -d ' ' -f 1 | tee "$samples/manifest.sha256"
{
	printf '\n### Evaluation manifest\n\n'
	printf -- '- Strategy: %s.\n' "$strategy"
	printf -- '- Manifest contains all %s targets exactly once.\n' "$(jq length "$scratch/result.json")"
	printf -- '- SHA-256: %s.\n' "$(<"$samples/manifest.sha256")"
} >>"$GITHUB_STEP_SUMMARY"
