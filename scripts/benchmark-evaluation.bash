set -euo pipefail

samples=$1
strategy=$2
chunk_size=${GATE_CHUNK_SIZE:-48}
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

measure_part() {
	local label=$1 condition=$2 part="$scratch/$1.json"
	measure "$label" "$part" "targets: $projection (builtins.filter (target: $condition) targets)"
	parts+=("$part")
}

nix --version | tee "$samples/evaluator.txt"
printf 'phase\twall_s\tuser_s\tsystem_s\tmax_rss_KiB\texit_status\n' >"$samples/evaluation.tsv"
measure inventory "$scratch/inventory.json" \
	'targets: map (target: { inherit (target) system cohort rootSuffix; }) targets'

projection='map (target: { inherit (target) rootSuffix rootDrvPath; })'
parts=()
case $strategy in
full)
	measure full "$scratch/result.json" "targets: $projection targets"
	;;
full-gc)
	GC_FREE_SPACE_DIVISOR=8 measure full-gc "$scratch/result.json" "targets: $projection targets"
	;;
system | cohort)
	jq -r --arg field "$strategy" 'map(.[$field]) | unique[]' "$scratch/inventory.json" >"$scratch/groups.txt"
	while IFS= read -r group; do
		if [[ ! $group =~ ^(aarch64|x86_64)-(darwin|linux)(-deploy)?$ ]]; then
			printf 'Unexpected %s: %s\n' "$strategy" "$group" >&2
			exit 1
		fi
		measure_part "$group" "target.$strategy == \"$group\""
	done <"$scratch/groups.txt"
	;;
x86-packages)
	measure_part packages 'target.rootSuffix == "x86_64-linux/packages"'
	jq 'map(select(.rootSuffix == "x86_64-linux/packages"))' \
		"$scratch/inventory.json" >"$scratch/scope.json"
	jq -e 'length == 1' "$scratch/scope.json" >/dev/null
	;;
x86-split)
	if [[ ! $chunk_size =~ ^[1-9][0-9]*$ ]]; then
		printf 'Invalid chunk size: %s\n' "$chunk_size" >&2
		exit 2
	fi
	jq -e 'all(.[].rootSuffix; test("^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$"))' "$scratch/inventory.json" >/dev/null
	jq -r --argjson size "$chunk_size" '
		def partition($label; $names): {label: $label, names: $names};
		partition("aarch64-darwin"; map(select(.system == "aarch64-darwin") | .rootSuffix)),
		partition("aarch64-linux"; map(select(.system == "aarch64-linux") | .rootSuffix)),
		partition("x86_64-linux-deploy"; map(select(.cohort == "x86_64-linux-deploy") | .rootSuffix)),
		partition("x86_64-linux-packages"; map(select(.rootSuffix == "x86_64-linux/packages") | .rootSuffix)),
		(map(select(.cohort == "x86_64-linux" and .rootSuffix != "x86_64-linux/packages") | .rootSuffix)
		| . as $names | range(0; length; $size) as $i
		| partition("x86_64-linux-checks-\($i)"; $names[$i:$i + $size]))
		| select(.names | length > 0)
		| [.label, (.names | tojson)] | @tsv
	' "$scratch/inventory.json" >"$scratch/chunks.tsv"
	while IFS=$'\t' read -r label chunk; do
		measure_part "$label" "builtins.elem target.rootSuffix (builtins.fromJSON ''$chunk'')"
	done <"$scratch/chunks.tsv"
	;;
*)
	printf 'Unknown evaluation strategy: %s\n' "$strategy" >&2
	exit 2
	;;
esac

if ((${#parts[@]})); then
	jq -s 'add' "${parts[@]}" >"$scratch/result.json"
fi

scope="$scratch/inventory.json"
if [[ $strategy == x86-packages ]]; then
	scope="$scratch/scope.json"
fi
jq -e --slurpfile scope "$scope" '
	(map(.rootSuffix) | sort) as $actual
	| ($scope[0] | map(.rootSuffix) | sort) as $expected
	| $actual == $expected and $actual == ($actual | unique)
' "$scratch/result.json" >/dev/null

jq -cS 'sort_by(.rootSuffix)' "$scratch/result.json" |
	sha256sum | cut -d ' ' -f 1 | tee "$samples/manifest.sha256"
{
	printf '\n### Evaluation manifest\n\n'
	printf -- '- Strategy: %s.\n' "$strategy"
	printf -- '- Manifest contains all %s selected targets exactly once.\n' "$(jq length "$scratch/result.json" | tee "$samples/target-count.txt")"
	printf -- '- SHA-256: %s.\n' "$(<"$samples/manifest.sha256")"
} | tee -a "$GITHUB_STEP_SUMMARY"
