# nix-store-info - Analyse your Nix store

# Colours
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

usage() {
	echo -e "${BOLD}nix-store-info${NC} - Analyse your Nix store

${BOLD}USAGE:${NC}
    nix-store-info [COMMAND] [OPTIONS]

${BOLD}COMMANDS:${NC}
    summary         Show store overview (default)
    largest [N]     Show N largest store paths (default: 20)
    roots           Show all GC roots and their sources
    direnv          Show nix-direnv managed environments
    duplicates      Find duplicate packages (different versions)
    why PATH        Show why a store path is kept (its roots)
    deps PATH       Show what a store path depends on
    tree PATH       Show dependency tree for a path
    gc-preview      Preview what garbage collection would free
    search PATTERN  Search for paths matching pattern

${BOLD}EXAMPLES:${NC}
    nix-store-info                    # Show summary
    nix-store-info largest 50         # Show 50 largest paths
    nix-store-info why /nix/store/... # Why is this path kept?
    nix-store-info search firefox     # Find firefox-related paths"
}

human_size() {
	numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1"
}

strip_hash() {
	sed 's/^[a-z0-9]*-//'
}

cmd_summary() {
	echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
	echo -e "${BOLD}                    Nix Store Summary${NC}"
	echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
	echo

	local store_size
	store_size=$(du -sb /nix/store 2>/dev/null | cut -f1)
	echo -e "${CYAN}Total store size:${NC} $(human_size "${store_size}")"

	local path_count
	path_count=$(find /nix/store -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
	echo -e "${CYAN}Number of paths:${NC} ${path_count}"

	local root_count
	root_count=$(nix-store --gc --print-roots 2>/dev/null | grep -cv "^/proc/")
	echo -e "${CYAN}GC roots:${NC} ${root_count}"

	echo
	echo -e "${YELLOW}Calculating live/dead paths (this may take a moment)...${NC}"
	local gc_count dead_size
	gc_count=$(nix-store --gc --print-dead 2>/dev/null | wc -l)
	dead_size=$(nix-store --gc --print-dead 2>/dev/null | xargs -r du -scb 2>/dev/null | tail -1 | cut -f1 || echo "0")
	echo -e "${CYAN}Dead paths (garbage):${NC} ${gc_count} paths ($(human_size "${dead_size}") reclaimable)"

	echo
	echo -e "${BOLD}Top 10 largest paths:${NC}"
	cmd_largest 10

	echo
	echo -e "${BOLD}GC root sources:${NC}"
	(
		set +o pipefail
		nix-store --gc --print-roots 2>/dev/null | grep -v "^/proc/" |
			sed 's| ->.*||' |
			sed 's|/[^/]*$||' |
			sort | uniq -c | sort -rn | head -10 |
			while read -r count path; do
				echo -e "  ${GREEN}${count}${NC} roots from ${BLUE}${path}${NC}"
			done
	)
}

cmd_largest() {
	local n=${1:-20}
	echo -e "${YELLOW}Scanning store paths...${NC}" >&2

	(
		set +o pipefail
		nix path-info --all -s 2>/dev/null |
			awk '{print $2, $1}' |
			sort -rn |
			head -n "${n}" |
			while read -r size path; do
				local name
				name=$(basename "${path}" | strip_hash)
				printf "${GREEN}%10s${NC}  %s\n" "$(human_size "${size}")" "${name}"
			done
	)
}

cmd_roots() {
	echo -e "${BOLD}GC Roots by source:${NC}"
	echo

	echo -e "${CYAN}Current user profile:${NC}"
	if [[ -L "${HOME}/.nix-profile" ]]; then
		readlink -f "${HOME}/.nix-profile"
	fi
	echo

	echo -e "${CYAN}Home Manager generations:${NC}"
	if [[ -d "${HOME}/.local/state/nix/profiles" ]]; then
		local hm_profiles
		hm_profiles=$(find "${HOME}/.local/state/nix/profiles" -maxdepth 1 -name 'home-manager*' 2>/dev/null)
		if [[ -n "${hm_profiles}" ]]; then
			echo "${hm_profiles}" | xargs -r ls -la
		else
			echo "  (none found)"
		fi
	else
		echo "  (no home-manager profiles)"
	fi
	echo

	echo -e "${CYAN}nix-direnv environments:${NC}"
	nix-store --gc --print-roots 2>/dev/null | grep -E '\.direnv|direnv' | head -20 || echo "  (none found)"
	echo

	echo -e "${CYAN}System profiles:${NC}"
	nix-store --gc --print-roots 2>/dev/null | grep -E '/nix/var/nix/profiles/(system|default)' | head -10 || echo "  (none found)"
	echo

	echo -e "${CYAN}Other roots:${NC}"
	nix-store --gc --print-roots 2>/dev/null |
		grep -v "^/proc/" |
		grep -v '\.direnv' |
		grep -v 'profiles/home-manager' |
		grep -v 'profiles/system' |
		grep -v 'profiles/default' |
		head -20
}

cmd_direnv() {
	echo -e "${BOLD}nix-direnv managed environments:${NC}"
	echo

	echo -e "${CYAN}Active direnv profiles:${NC}"

	declare -A seen_projects
	nix-store --gc --print-roots 2>/dev/null |
		grep '\.direnv' |
		while IFS=' -> ' read -r root_path store_path; do
			local project_dir
			project_dir=${root_path%/.direnv/*}

			[[ -n ${seen_projects[${project_dir}]:-} ]] && continue
			seen_projects[${project_dir}]=1

			if [[ -n "${store_path}" ]]; then
				local size
				size=$(nix path-info -S "${store_path}" 2>/dev/null | awk '{print $2}' || echo "0")
				printf "  ${BLUE}%-50s${NC} ${GREEN}%10s${NC}\n" "${project_dir}" "$(human_size "${size}")"
			fi
		done

	echo
	echo -e "${CYAN}Finding flake.nix files in common locations...${NC}"

	local search_dirs=(
		"${HOME}/dev"
		"${HOME}/src"
		"${HOME}/projects"
		"${HOME}/code"
		"${HOME}/work"
	)

	for dir in "${search_dirs[@]}"; do
		[[ -d "${dir}" ]] || continue

		find "${dir}" -maxdepth 4 -name "flake.nix" -type f 2>/dev/null |
			while read -r flake; do
				local project
				project=$(dirname "${flake}")
				if [[ -d "${project}/.direnv" ]]; then
					echo -e "  ${GREEN}✓${NC} ${project}"
				else
					echo -e "  ${YELLOW}○${NC} ${project} ${YELLOW}(no .direnv)${NC}"
				fi
			done
	done
}

cmd_duplicates() {
	echo -e "${BOLD}Duplicate packages (multiple versions):${NC}"
	echo

	(
		set +o pipefail
		nix path-info --all 2>/dev/null |
			xargs -I{} basename {} |
			strip_hash |
			sed 's/-[0-9].*$//' |
			sort | uniq -c | sort -rn |
			awk '$1 > 1 {print}' |
			head -30 |
			while read -r count name; do
				echo -e "  ${YELLOW}${count}×${NC} ${name}"
			done
	)
}

resolve_path() {
	local path=$1

	if [[ "${path}" =~ ^/nix/store/ ]]; then
		echo "${path}"
		return 0
	fi

	local found
	found=$(nix path-info --all 2>/dev/null | grep "${path}" | head -1)
	if [[ -n "${found}" ]]; then
		echo "${found}"
		return 0
	fi

	echo -e "${RED}Error: Path not found in store${NC}" >&2
	return 1
}

cmd_why() {
	local path
	path=$(resolve_path "$1") || return 1

	echo -e "${BOLD}Why is this path kept?${NC}"
	echo -e "${CYAN}Path:${NC} ${path}"
	echo

	echo -e "${CYAN}Direct roots:${NC}"
	nix-store --query --roots "${path}" 2>/dev/null | head -20

	echo
	echo -e "${CYAN}Referrers (what depends on this):${NC}"
	nix-store --query --referrers "${path}" 2>/dev/null | head -10
}

cmd_deps() {
	local path
	path=$(resolve_path "$1") || return 1

	echo -e "${BOLD}Dependencies of:${NC} ${path}"
	echo

	(
		set +o pipefail
		nix-store --query --requisites "${path}" 2>/dev/null |
			while read -r dep; do
				local name size
				name=$(basename "${dep}" | strip_hash)
				size=$(nix path-info -S "${dep}" 2>/dev/null | awk '{print $2}' || echo "0")
				printf "${GREEN}%10s${NC}  %s\n" "$(human_size "${size}")" "${name}"
			done | sort -rh | head -30
	)
}

cmd_tree() {
	local path
	path=$(resolve_path "$1") || return 1

	echo -e "${BOLD}Dependency tree for:${NC} ${path}"
	echo

	nix path-info --recursive "${path}" 2>/dev/null | head -50
}

cmd_gc_preview() {
	echo -e "${BOLD}Garbage Collection Preview${NC}"
	echo

	local dead_paths dead_count
	dead_paths=$(nix-store --gc --print-dead 2>/dev/null)
	dead_count=$(echo "${dead_paths}" | grep -c . || echo "0")

	if [[ "${dead_count}" -eq 0 ]]; then
		echo -e "${GREEN}No garbage to collect!${NC}"
		return
	fi

	local dead_size
	dead_size=$(echo "${dead_paths}" | xargs -r du -scb 2>/dev/null | tail -1 | cut -f1 || echo "0")

	echo -e "${CYAN}Reclaimable:${NC} $(human_size "${dead_size}") across ${dead_count} paths"
	echo
	echo -e "${CYAN}Largest dead paths:${NC}"

	(
		set +o pipefail
		while read -r path; do
			size=$(du -sb "${path}" 2>/dev/null | cut -f1)
			echo "${size} ${path}"
		done <<<"${dead_paths}" |
			sort -rn | head -20 |
			while read -r size path; do
				local name
				name=$(basename "${path}" | strip_hash)
				printf "${GREEN}%10s${NC}  %s\n" "$(human_size "${size}")" "${name}"
			done
	)

	echo
	echo -e "${YELLOW}Run 'nix-collect-garbage' to reclaim this space${NC}"
	echo -e "${YELLOW}Run 'nix-collect-garbage -d' to also delete old generations${NC}"
}

cmd_search() {
	local pattern=$1

	echo -e "${BOLD}Searching for:${NC} ${pattern}"
	echo

	nix path-info --all 2>/dev/null |
		grep -i "${pattern}" |
		while read -r path; do
			local name size
			name=$(basename "${path}" | strip_hash)
			size=$(nix path-info -S "${path}" 2>/dev/null | awk '{print $2}' || echo "0")
			printf "${GREEN}%10s${NC}  %s\n" "$(human_size "${size}")" "${name}"
			echo -e "           ${BLUE}${path}${NC}"
		done
}

case "${1:-summary}" in
summary)
	cmd_summary
	;;
largest)
	cmd_largest "${2:-20}"
	;;
roots)
	cmd_roots
	;;
direnv)
	cmd_direnv
	;;
duplicates)
	cmd_duplicates
	;;
why)
	if [[ -z "${2:-}" ]]; then
		echo "Usage: nix-store-info why PATH" >&2
		exit 1
	fi
	cmd_why "$2"
	;;
deps)
	if [[ -z "${2:-}" ]]; then
		echo "Usage: nix-store-info deps PATH" >&2
		exit 1
	fi
	cmd_deps "$2"
	;;
tree)
	if [[ -z "${2:-}" ]]; then
		echo "Usage: nix-store-info tree PATH" >&2
		exit 1
	fi
	cmd_tree "$2"
	;;
gc-preview)
	cmd_gc_preview
	;;
search)
	if [[ -z "${2:-}" ]]; then
		echo "Usage: nix-store-info search PATTERN" >&2
		exit 1
	fi
	cmd_search "$2"
	;;
-h | --help | help)
	usage
	;;
*)
	echo "Unknown command: $1" >&2
	usage >&2
	exit 1
	;;
esac
