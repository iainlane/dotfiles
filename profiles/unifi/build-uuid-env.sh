# shellcheck shell=bash
# UniFi OS identifies the instance by a UUID it is given. Derive it from the
# machine id so the same host keeps the same identity across restarts and
# rebuilds, and write it where the container reads its environment from.

set -euo pipefail

ENV_FILE="/run/unifi/runtime.env"

if [ -f "$ENV_FILE" ] && grep -q '^UOS_UUID=' "$ENV_FILE"; then
	exit 0
fi

MACHINE_ID="$(cat /etc/machine-id)"
UUID="$(uuidgen -s -n @dns -N "unifi-os-$MACHINE_ID")"

printf 'UOS_UUID=%s\n' "$UUID" >"$ENV_FILE"
