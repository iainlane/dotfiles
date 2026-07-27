#!/usr/bin/env bash

set -euo pipefail

if [[ $# -eq 0 ]]; then
	printf 'usage: %s <nix build arguments...>\n' "${0}" >&2
	exit 2
fi

attempts=3

# Nix reports remote builder and copy failures with the same exit statuses as
# deterministic failures, so there is no reliable transport-only classifier.
for ((attempt = 1; attempt <= attempts; attempt += 1)); do
	set +e
	nix build "$@"
	status=$?
	set -e

	if [[ "${status}" -eq 0 ]]; then
		exit 0
	fi

	if [[ "${attempt}" -eq "${attempts}" ]]; then
		exit "${status}"
	fi

	# Realised derivations and completed store paths remain in the local store,
	# so each attempt resumes without repeating completed work.
	delay=$((attempt * 15))
	printf \
		'Nix build failed (attempt %d/%d); retrying in %d seconds.\n' \
		"${attempt}" "${attempts}" "${delay}" >&2
	sleep "${delay}"
done
