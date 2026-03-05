#!/usr/bin/env bash
set -euo pipefail

# Build the Ultrafeeder feed settings right before start so this host always
# uses stable IDs and sends data to all configured aggregators with a different
# UUID for each.

# This script runs in `ExecStartPre` of the `podman-ultrafeeder` unit. It builds
# a runtime env file with UUID and ULTRAFEEDER_CONFIG derived from:
#
# 1) The per-machine ID in `/etc/machine-id`.
# 2) `ADSB_TARGETS` sourced from `./ultrafeeder-config.nix`.

# ADSB_TARGETS format:
#   name,adsb_host,adsb_port,mlat_host,mlat_port
if [ -z "${ADSB_TARGETS:-}" ]; then
	echo "ADSB_TARGETS environment variable is required" >&2
	exit 1
fi

# MLATHUB_TARGETS format (optional):
#   name,host,port,protocol
# Example:
#   planewatch,planewatch,30105,beast_in

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
	echo "XDG_RUNTIME_DIR environment variable is required" >&2
	exit 1
fi

runtime_env_file="${XDG_RUNTIME_DIR}/adsb/ultrafeeder-runtime.env"
mkdir -p "$(dirname "${runtime_env_file}")"
machine_id="$(tr -d '\n' </etc/machine-id)"

mk_uuid() {
	local seed="$1"
	local hash
	# Stable UUID from md5(seed), formatted as 8-4-4-4-12.
	hash="$(printf '%s' "$seed" | md5sum | cut -d ' ' -f1)"
	printf '%s-%s-%s-%s-%s' \
		"${hash:0:8}" \
		"${hash:8:4}" \
		"${hash:12:4}" \
		"${hash:16:4}" \
		"${hash:20:12}"
}

station_uuid="$(mk_uuid "station:${machine_id}")"
ultrafeeder_config=""

# Generate one ADS-B and one MLAT connector for every target.
# Each target gets a deterministic UUID: <target name>:<machine-id>.
IFS=';' read -r -a targets <<<"${ADSB_TARGETS}"
for target in "${targets[@]}"; do
	[ -n "${target}" ] || continue

	IFS=',' read -r name adsb_host adsb_port mlat_host mlat_port <<<"${target}"
	if [ -z "${name}" ] || [ -z "${adsb_host}" ] || [ -z "${adsb_port}" ] || [ -z "${mlat_host}" ] || [ -z "${mlat_port}" ]; then
		echo "invalid ADSB_TARGETS entry: ${target}" >&2
		exit 1
	fi

	target_uuid="$(mk_uuid "${name}:${machine_id}")"
	ultrafeeder_config+="adsb,${adsb_host},${adsb_port},beast_reduce_plus_out,uuid=${target_uuid};"
	ultrafeeder_config+="mlat,${mlat_host},${mlat_port},uuid=${target_uuid};"
done

# Add MLAT return streams from external feeders into ultrafeeder's MLAT hub.
if [ -n "${MLATHUB_TARGETS:-}" ]; then
	IFS=';' read -r -a mlathub_targets <<<"${MLATHUB_TARGETS}"
	for target in "${mlathub_targets[@]}"; do
		[ -n "${target}" ] || continue

		IFS=',' read -r name host port protocol <<<"${target}"
		if [ -z "${name}" ] || [ -z "${host}" ] || [ -z "${port}" ] || [ -z "${protocol}" ]; then
			echo "invalid MLATHUB_TARGETS entry: ${target}" >&2
			exit 1
		fi

		ultrafeeder_config+="mlathub,${host},${port},${protocol};"
	done
fi

# Container.EnvironmentFile reads this file at start.
cat >"${runtime_env_file}" <<EOF
UUID=${station_uuid}
ULTRAFEEDER_CONFIG=${ultrafeeder_config}
EOF
