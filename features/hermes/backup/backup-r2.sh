# shellcheck shell=bash
#
# Snapshot the Hermes state into a directory and hand it to `r2 backup`. Every
# setting arrives in the environment, so nothing is substituted into this file
# and shellcheck can run over it:
#
#   HERMES_STATE_DIR     state directory to back up, or
#   HERMES_STATE_VOLUME  podman volume whose mountpoint to back up
#
# plus everything `r2 backup` reads.
set -euo pipefail
umask 077

# The state lives in a podman named volume; resolve its host mountpoint.
if [ -z "${HERMES_STATE_DIR:-}" ] && [ -n "${HERMES_STATE_VOLUME:-}" ]; then
	HERMES_STATE_DIR="$(podman volume inspect --format '{{.Mountpoint}}' "${HERMES_STATE_VOLUME}")"
fi

: "${HERMES_STATE_DIR:?}"

work="$(mktemp -d)"
# The snapshot copies Hermes' read-only bundled skills, whose leaf directories
# drop owner-write, so restore owner-write before removing the tree.
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
	--exclude='/.hermes/kanban.db*' \
	--exclude='/.hermes/shared-state.db*' \
	--exclude='/.hermes/cron/deliveries.db*' \
	--exclude='/.hermes/plugin-data/agent-plugin-hermes-inbox-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/inbox.sqlite3*' \
	"${HERMES_STATE_DIR}/" "${snap}/"

for db in state.db memory_store.db kanban.db shared-state.db cron/deliveries.db; do
	src="${HERMES_STATE_DIR}/.hermes/${db}"
	if [ -f "${src}" ]; then
		mkdir -p "$(dirname "${snap}/.hermes/${db}")"
		sqlite3 "${src}" ".backup '${snap}/.hermes/${db}'"
	fi
done

shopt -s nullglob
for inbox_db in "${HERMES_STATE_DIR}"/.hermes/plugin-data/agent-plugin-hermes-inbox-????????/inbox.sqlite3; do
	data_namespace="$(basename "$(dirname "${inbox_db}")")"
	if [[ ! "${data_namespace}" =~ ^agent-plugin-hermes-inbox-[0-9a-f]{8}$ ]]; then
		continue
	fi

	snapshot_dir="${snap}/.hermes/plugin-data/${data_namespace}"
	mkdir -p "${snapshot_dir}"
	sqlite3 "${inbox_db}" ".backup '${snapshot_dir}/inbox.sqlite3'"
done

BACKUP_SOURCE="${snap}" r2 backup
