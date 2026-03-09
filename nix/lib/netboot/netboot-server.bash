set -euo pipefail

dhcp_no_bind=1
http_port=80
listen_addr="0.0.0.0"
extra_cmdline=""
password="${LIVE_NIXOS_PASSWORD-}"
password_hash="${LIVE_NIXOS_PASSWORD_HASH-}"
authorized_keys_files=()

usage() {
	cat <<EOF
Usage: ${NETBOOT_DISPLAY_NAME}-netboot [options]

Serve a NixOS netboot installer for ${NETBOOT_DISPLAY_NAME} via pixiecore.

Options:
  --password PASSWORD        Temporary root password for the live installer
  --password-hash HASH       Hashed temporary root password
  --authorized-keys-file FILE
                             Public key file to fetch into the live installer
  --append-cmdline TEXT      Extra kernel cmdline to append
  --listen-addr ADDR         Address for pixiecore to listen on (default: 0.0.0.0)
  --http-port PORT           HTTP/status port for pixiecore (default: 80)
  --bind-dhcp                Bind DHCP directly instead of proxying an existing DHCP server
  --help                     Show this help

Environment:
  LIVE_NIXOS_PASSWORD
  LIVE_NIXOS_PASSWORD_HASH

Notes:
  - By default pixiecore runs with --dhcp-no-bind so it can coexist with your
    existing DHCP server on the LAN.
  - The live installer enables sshd. Authentication can be provided with a
    temporary root password or one or more authorized key files.
  - pixiecore needs root privileges, so this command escalates only for the final
    pixiecore step via sudo.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--password)
		password="$2"
		shift 2
		;;
	--password-hash)
		password_hash="$2"
		shift 2
		;;
	--authorized-keys-file)
		authorized_keys_files+=("$2")
		shift 2
		;;
	--append-cmdline)
		extra_cmdline+=" $2"
		shift 2
		;;
	--listen-addr)
		listen_addr="$2"
		shift 2
		;;
	--http-port)
		http_port="$2"
		shift 2
		;;
	--bind-dhcp)
		dhcp_no_bind=0
		shift
		;;
	--help)
		usage
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

if [[ -n "$password" && -n "$password_hash" ]]; then
	echo "Pass only one of --password or --password-hash." >&2
	exit 1
fi

if [[ -z "$password" && -z "$password_hash" && "${#authorized_keys_files[@]}" -eq 0 ]]; then
	if [[ -t 0 && -t 1 ]]; then
		read -r -s -p "Temporary root password for the live installer: " password
		echo
		read -r -s -p "Confirm password: " password_confirm
		echo
		if [[ "$password" != "$password_confirm" ]]; then
			echo "Passwords did not match." >&2
			exit 1
		fi
	else
		echo "Provide --password, --password-hash, LIVE_NIXOS_PASSWORD, LIVE_NIXOS_PASSWORD_HASH, or --authorized-keys-file." >&2
		exit 1
	fi
fi

if [[ -n "$password" && "$password" =~ [[:space:]] ]]; then
	echo "Passwords passed on the kernel command line must not contain whitespace." >&2
	exit 1
fi

for key_file in "${authorized_keys_files[@]}"; do
	if [[ ! -f "$key_file" ]]; then
		echo "Authorized key file not found: $key_file" >&2
		exit 1
	fi
done

if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required to start pixiecore." >&2
	exit 1
fi

echo "Resolving ${NETBOOT_DISPLAY_NAME} netboot artifacts from ${NETBOOT_ARTIFACT_ATTR}"
if ! artifacts=$(nix build --no-link --print-out-paths "${NETBOOT_FLAKE_REF}#${NETBOOT_ARTIFACT_ATTR}"); then
	cat >&2 <<EOF
Failed to build or download the ${NETBOOT_DISPLAY_NAME} netboot installer artifacts.
This output targets the host architecture declared for ${NETBOOT_DISPLAY_NAME}.
If you're running this from a different system, you need substituters for the
installer artifacts or a compatible builder.
EOF
	exit 1
fi

cmdline=$(<"$artifacts/cmdline")
cmdline+="${extra_cmdline}"
if [[ -n "$password_hash" ]]; then
	cmdline+=" live.nixos.passwordHash=$password_hash"
elif [[ -n "$password" ]]; then
	cmdline+=" live.nixos.password=$password"
fi

for key_file in "${authorized_keys_files[@]}"; do
	cmdline+=" live.nixos.authorizedKeysUrl={{ ID \"$key_file\" }}"
done

pixiecore_args=(
	boot
	"$artifacts/bzImage"
	"$artifacts/initrd"
	--bootmsg "$NETBOOT_BOOT_MESSAGE"
	--cmdline "$cmdline"
	--listen-addr "$listen_addr"
	--port "$http_port"
	--status-port "$http_port"
)

if ((dhcp_no_bind)); then
	pixiecore_args+=(--dhcp-no-bind)
fi

echo "Starting pixiecore for ${NETBOOT_DISPLAY_NAME} on ${listen_addr}:${http_port}"
exec sudo pixiecore "${pixiecore_args[@]}"
