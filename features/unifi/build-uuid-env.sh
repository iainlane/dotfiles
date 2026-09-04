# shellcheck shell=bash
# UniFi OS identifies the instance by a UUID it is given. Derive it from the
# machine id so the same host keeps the same identity across restarts and
# rebuilds, and write it where the container reads its environment from.

set -euo pipefail

# systemd sets RUNTIME_DIRECTORY, and creates the directory, from the unit's
# `RuntimeDirectory=`. The container's `EnvironmentFile=` names the same path,
# built from the same setting.
if [ -z "${RUNTIME_DIRECTORY:-}" ]; then
	echo "RUNTIME_DIRECTORY environment variable is required" >&2
	exit 1
fi

ENV_FILE="${RUNTIME_DIRECTORY}/runtime.env"

if [ -f "$ENV_FILE" ] && grep -q '^UOS_UUID=' "$ENV_FILE"; then
	exit 0
fi

MACHINE_ID="$(cat /etc/machine-id)"
UUID="$(uuidgen -s -n @dns -N "unifi-os-$MACHINE_ID")"

printf 'UOS_UUID=%s\n' "$UUID" >"$ENV_FILE"
