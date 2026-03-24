# shellcheck shell=bash
# Loads the UniFi OS container image into podman (if needed) and generates
# a deterministic UUID for the instance. Designed to run as ExecStartPre.

IMAGE_REF="$1"
IMAGE_TAR="$2"

# Load image if not already present
if ! podman image exists "$IMAGE_REF"; then
	echo "Loading UniFi OS image from $IMAGE_TAR..."
	load_output="$(podman load -i "$IMAGE_TAR")"
	source_ref="$(printf '%s\n' "$load_output" | sed -n -E 's/^Loaded image(\(s\))?: //p' | tail -n1)"

	if [ -z "$source_ref" ]; then
		source_ref="$(tar -xOf "$IMAGE_TAR" manifest.json | jq -r '.[0].RepoTags[0] // empty')"
	fi

	if [ -n "$source_ref" ] && [ "$source_ref" != "$IMAGE_REF" ]; then
		podman image tag "$source_ref" "$IMAGE_REF"
	fi

	if ! podman image exists "$IMAGE_REF"; then
		echo "Failed to load UniFi image as $IMAGE_REF" >&2
		exit 1
	fi
fi

# Generate deterministic UUIDv5 from machine-id
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/unifi"
mkdir -p "$RUNTIME_DIR"

ENV_FILE="$RUNTIME_DIR/runtime.env"

if [ -f "$ENV_FILE" ] && grep -q '^UOS_UUID=' "$ENV_FILE" 2>/dev/null; then
	exit 0
fi

MACHINE_ID="$(cat /etc/machine-id)"
UUID="$(uuidgen -s -n @dns -N "unifi-os-$MACHINE_ID")"
printf 'UOS_UUID=%s\n' "$UUID" >"$ENV_FILE"
echo "Generated UOS_UUID=$UUID"
