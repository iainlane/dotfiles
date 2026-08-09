#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils git
#!nix-shell -I nixpkgs=flake:nixpkgs
# shellcheck shell=bash

# Clone the secrets repository, run a generator against the clone, then commit
# and push whatever the generator wrote.
#
# The generator takes the directory of the clone as its last argument.
#
# Usage: with-secrets-repo <secrets_repo> <commit_message> <generator> [args...]

set -euo pipefail

# shellcheck source=scripts/lib/just-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/just-common.bash"

secrets_repo="${1}"
commit_message="${2}"
shift 2

ensure_repo_root

log_step "Cloning secrets repo"
secrets_dir="$(make_temp_dir)"
git clone "${secrets_repo#git+}" "${secrets_dir}"

"${@}" "${secrets_dir}"

cd "${secrets_dir}"

log_step "Committing and pushing secrets repo"
git add -A

if git diff --cached --quiet; then
	echo "    No changes to secrets repo"
	exit 0
fi

git commit -m "${commit_message}"
git push
