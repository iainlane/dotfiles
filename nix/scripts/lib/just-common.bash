#!/usr/bin/env bash

# Shared helpers for the extracted just scripts: repo-root setup, logging, temp
# cleanup, and encrypted file helpers.
#
# Usage: source scripts/lib/just-common.bash

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMMON_LIB_DIR
SCRIPTS_DIR="$(cd "${COMMON_LIB_DIR}/.." && pwd)"
readonly SCRIPTS_DIR
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"
readonly REPO_ROOT

# Only print ANSI colour codes when stdout is an interactive terminal.
if [[ -t 1 ]]; then
	_green=$'\033[0;32m'
	_red=$'\033[0;31m'
	_yellow=$'\033[1;33m'
	_reset=$'\033[0m'
else
	_green=''
	_red=''
	_yellow=''
	_reset=''
fi

declare -ag _TEMP_PATHS=()
declare -ag _EXIT_HANDLERS=()

log_step() {
	printf '%s==> %s%s\n' "${_green}" "$*" "${_reset}"
}

log_warn() {
	printf '%swarn%s %s\n' "${_yellow}" "${_reset}" "$*" >&2
}

log_note() {
	printf '%snote%s %s\n' "${_yellow}" "${_reset}" "$*"
}

die() {
	printf '%serror%s %s\n' "${_red}" "${_reset}" "$*" >&2
	exit 1
}

ensure_repo_root() {
	if ! cd "${REPO_ROOT}"; then
		exit 1
	fi
}

make_temp_dir() {
	local path

	path="$(mktemp -d)"
	_TEMP_PATHS+=("${path}")
	printf '%s\n' "${path}"
}

make_temp_file() {
	local path

	path="$(mktemp)"
	_TEMP_PATHS+=("${path}")
	printf '%s\n' "${path}"
}

register_exit_handler() {
	_EXIT_HANDLERS+=("$1")
}

encrypt_yaml_file() {
	local plaintext_path="${1}"
	local output_path="${2}"
	local filename_override="${3}"

	sops --encrypt --input-type yaml --output-type yaml --filename-override "${filename_override}" "${plaintext_path}" >"${output_path}"
}

shred_tree() {
	local path="${1}"

	if [[ ! -e "${path}" ]]; then
		return 0
	fi

	if [[ -d "${path}" ]]; then
		find "${path}" -type f -exec shred -u {} + 2>/dev/null || true
		rm -rf "${path}"
		return 0
	fi

	shred -u "${path}" 2>/dev/null || rm -f "${path}"
}

_cleanup_registered_paths() {
	if [[ ${#_TEMP_PATHS[@]} -eq 0 ]]; then
		return 0
	fi
	rm -rf -- "${_TEMP_PATHS[@]}"
}

_run_exit_handlers() {
	local status=$?
	local handler

	# Run caller-provided cleanup first, then remove any temp paths made here.
	for handler in "${_EXIT_HANDLERS[@]}"; do
		"${handler}" "${status}"
	done

	_cleanup_registered_paths
	return "${status}"
}

trap _run_exit_handlers EXIT
