# shellcheck shell=bash
#
# Snapshot the Hermes state into a directory and hand it to the uploader.
# Driven entirely by the environment so it stays a plain, checkable shell
# script:
#
#   HERMES_STATE_DIR     state directory to back up, or
#   HERMES_STATE_VOLUME  podman volume whose mountpoint to back up
#
# plus everything `r2-upload` reads.
set -euo pipefail
umask 077

# The state lives in a podman named volume; resolve its host mountpoint.
if [ -z "${HERMES_STATE_DIR:-}" ] && [ -n "${HERMES_STATE_VOLUME:-}" ]; then
	HERMES_STATE_DIR="$(podman volume inspect --format '{{.Mountpoint}}' "${HERMES_STATE_VOLUME}")"
fi

: "${HERMES_STATE_DIR:?}"

work="$(mktemp -d)"
# The snapshot copies Hermes' read-only bundled skills, whose leaf
# directories drop owner-write, so restore it before removing the tree.
trap 'chmod -R u+w "${work}" 2>/dev/null || true; rm -rf "${work}"' EXIT
snap="${work}/snapshot"
mkdir -p "${snap}/.hermes"

# Copy everything except the live SQLite databases. Those are captured
# consistently below with the SQLite online backup API.
# config.yaml, SOUL.md, and AGENTS.md are read-only Nix-store mounts:
# reproducible, so not worth backing up, and their host-side mountpoint stubs
# can be owned by a container subuid and unreadable to this user.
rsync -a --numeric-ids \
	--exclude=/current-package \
	--exclude='/.hermes/config.yaml' \
	--exclude='/.hermes/SOUL.md' \
	--exclude='/workspace/AGENTS.md' \
	--exclude='/.hermes/state.db*' \
	--exclude='/.hermes/memory_store.db*' \
	--exclude='/.hermes/kanban.db-wal' \
	--exclude='/.hermes/kanban.db-shm' \
	"${HERMES_STATE_DIR}/" "${snap}/"

for db in state.db memory_store.db kanban.db; do
	src="${HERMES_STATE_DIR}/.hermes/${db}"
	if [ -f "${src}" ]; then
		sqlite3 "${src}" ".backup '${snap}/.hermes/${db}'"
	fi
done

BACKUP_SOURCE="${snap}" r2-upload
