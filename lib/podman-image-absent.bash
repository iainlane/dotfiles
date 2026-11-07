#!/usr/bin/env bash
#
# Exit 0 when the image reference given as the first argument is not in
# local podman storage, and 1 when it is. Written for `ExecCondition=` on a
# Nix-built image unit: an exit status of 1 makes systemd skip the pull and
# treat the unit as finished successfully.

set -euo pipefail

if podman image exists "${1}"; then
	exit 1
fi
