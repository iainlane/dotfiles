#!/usr/bin/env bash

set -euo pipefail

if [[ $# -eq 0 ]]; then
	printf 'usage: %s <nix arguments...>\n' "${0}" >&2
	exit 2
fi

attempts=3

# Nix reports a remote builder or copy failure with the same exit statuses as a
# deterministic one, so the status does not say which of the two happened.
# Retry every failure, up to `attempts` runs in total.
for ((attempt = 1; attempt <= attempts; attempt += 1)); do
	set +e
	nix "$@"
	status=$?
	set -e

	if [[ "${status}" -eq 0 ]]; then
		exit 0
	fi

	if [[ "${attempt}" -eq "${attempts}" ]]; then
		exit "${status}"
	fi

	# Derivations already realised stay in the local store, so a retry does not
	# repeat the work that succeeded.
	delay=$((attempt * 15))
	printf \
		'Nix command failed (attempt %d/%d); retrying in %d seconds.\n' \
		"${attempt}" "${attempts}" "${delay}" >&2
	sleep "${delay}"
done
