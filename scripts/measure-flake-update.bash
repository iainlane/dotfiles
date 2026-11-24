set -euo pipefail

mark() {
	printf '%s\t%s\n' "$EPOCHREALTIME" "$1" >>"$samples/phases.tsv"
}

stream_update() {
	local line phase
	while IFS= read -r line; do
		case "$line" in
		'+ nix flake update '*) mark relock ;;
		'+ nix run .#update-plan -- describe') mark maintenance-plan ;;
		'+ nix eval --json '*updaterMetadata) mark updater-metadata ;;
		'+ nix build '*'.updaterScripts.'*) mark "build:${line##*.updaterScripts.}" ;;
		'+ /nix/store/'*'/bin/update-'*' --refresh')
			phase=${line##*/bin/}
			mark "refresh:${phase% --refresh}"
			;;
		'+ bash scripts/check-evaluation.bash') mark evaluation ;;
		esac
		printf '%s\n' "$line"
	done
}

worker() {
	: "${RUNNER_TEMP:?Missing runner temporary directory}" "${GIT_SSH_COMMAND:?Missing private input access}"
	local scope limit
	scope=$(awk -F: '$1 == 0 {print $3}' /proc/self/cgroup)
	limit=$(<"/sys/fs/cgroup${scope}/memory.max")
	if [[ $limit != "$budget" ]]; then
		printf 'Memory limit is %s; expected %s bytes.\n' "$limit" "$budget" >&2
		exit 1
	fi

	export NIX_REMOTE=local
	if [[ -n ${GATE_STRATEGY:-} ]]; then
		mark prepare-benchmark
		local nixpkgs=github:nixos/nixpkgs/4fe25e12eb9f4c744966dd3de5a05246cf098601
		nix shell "$nixpkgs#nix" "$nixpkgs#time" --option allow-import-from-derivation false \
			--command "$BASH" "$GATE_BENCHMARK" "$samples" "$GATE_STRATEGY"
		return
	fi
	if [[ ${PROFILE_GATE:-false} == true ]]; then
		export FLAKE_UPDATE_PROFILE_DIR="$samples/evaluation"
		mkdir -p "$FLAKE_UPDATE_PROFILE_DIR"
	fi
	mark build-lock-summariser
	nix build .#flake-lock-summary --no-link
	mark build-update-runner
	nix build .#update-runner --out-link "$RUNNER_TEMP/diagnostic-update-runner"
	mark start-updates
	"$RUNNER_TEMP/diagnostic-update-runner/bin/update-runner" inputs --stage \
		2>&1 >"$RUNNER_TEMP/diagnostic-update-report.md" | stream_update
	mark updates-completed
}

sample_scope() {
	local scope metrics phase disk
	scope=$(systemctl show --property ControlGroup --value "$unit" 2>/dev/null) || return 0
	[[ -n $scope ]] || return 0
	scope=/sys/fs/cgroup${scope}
	metrics=$(awk '
		FILENAME ~ /memory.current$/ { current = $1 }
		FILENAME ~ /memory.peak$/ { peak = $1 }
		FILENAME ~ /memory.stat$/ && $1 == "anon" { anon = $2 }
		FILENAME ~ /memory.stat$/ && $1 == "file" { file = $2 }
		FILENAME ~ /memory.events$/ && $1 == "oom" { oom = $2 }
		FILENAME ~ /memory.events$/ && $1 == "oom_kill" { killed = $2 }
		$1 == "MemAvailable:" { free = $2 }
		$1 == "SwapFree:" { swap = $2 }
		END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", current, peak, anon, file, oom, killed, free, swap }
	' "$scope"/memory.{current,peak,stat,events} /proc/meminfo 2>/dev/null) || return 0
	phase=$(tail -n 1 "$samples/phases.tsv" | cut -f2)
	disk=$(df -P -B1 /nix/store | awk 'NR == 2 {print $4}')
	printf '%s\t%s\t%s\t%s\n' "$EPOCHREALTIME" "$phase" "$metrics" "$disk" >>"$samples/resources.tsv"
}

monitor_scope() {
	local ticks=0
	while :; do
		sample_scope
		if ((ticks % 6 == 0)); then
			tail -n 1 "$samples/resources.tsv"
		fi
		ticks=$((ticks + 1))
		sleep 5
	done
}

summarise() {
	local status=$1
	{
		printf '### Flake update diagnostics\n\n'
		printf -- '- Workload memory limit: %s bytes. Swap disabled for the probe.\n' "$budget"
		printf -- '- Workload exit status: %s.\n' "$status"
		awk -F '\t' '
			NR > 1 {
				if ($4 > peak) { peak = $4; phase = $2 }
				if ($8 > killed) killed = $8
			}
			END {
				if (NR < 2) { print "- No cgroup resource samples collected."; exit }
				printf "- Cgroup peak: %.2f GiB (first observed during `%s`).\n", peak / 1073741824, phase
				printf "- Observed cgroup OOM kills: %d.\n", killed
			}
		' "$samples/resources.tsv"
		printf -- '- Kernel OOM messages retained: %s.\n' "$(wc -l <"$samples/kernel-oom.log")"
	} | tee -a "$GITHUB_STEP_SUMMARY"
}

if [[ ${1:-} == worker ]]; then
	budget=$2
	samples=$3
	worker
	exit
fi

budget=$(($1 * 1024 * 1024 * 1024))
samples=$2
unit=flake-update-diagnostics.scope
mkdir -p "$samples"
printf 'timestamp\tphase\n' >"$samples/phases.tsv"
columns='timestamp phase current_B peak_B anon_B file_B oom oom_kill available_KiB swap_free_KiB disk_free_B'
tr ' ' '\t' <<<"$columns" >"$samples/resources.tsv"
mark start-scope
started=$(date '+%Y-%m-%d %H:%M:%S')
{
	uname -srv
	nproc
	awk '/^(MemTotal|SwapTotal):/' /proc/meminfo
	df -h /nix/store
	nix --version
	nix config show | grep -E '^(max-jobs|cores) = '
} | tee "$samples/runner.txt"

monitor_scope &
monitor=$!
trap 'kill "$monitor" 2>/dev/null || true' EXIT
status=0
preserve=RUNNER_TEMP,GIT_SSH_COMMAND,GH_TOKEN,GITHUB_TOKEN,CI,NIX_SSL_CERT_FILE,PROFILE_GATE
preserve+=,GATE_STRATEGY,GATE_BENCHMARK,GATE_CHUNK_SIZE,GITHUB_STEP_SUMMARY
sudo -n --preserve-env="$preserve" systemd-run --scope --quiet --unit="$unit" \
	--property=MemoryMax="$budget" --property=MemorySwapMax=0 \
	sudo -n --preserve-env="$preserve" -u "#$UID" -- env "HOME=$HOME" "PATH=$PATH" \
	"$BASH" "$(realpath "${BASH_SOURCE[0]}")" worker "$budget" "$samples" || status=$?
kill "$monitor" 2>/dev/null || true
wait "$monitor" 2>/dev/null || true
sudo -n journalctl -k --since "$started" --no-pager -o cat |
	grep -Ei 'oom-kill|out of memory|Killed process' >"$samples/kernel-oom.log" || true
summarise "$status"
exit "$status"
