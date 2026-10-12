# shellcheck shell=bash

set -euo pipefail

program="$1"
fixture="$(mktemp -d)"
fixture="$(cd "${fixture}" && pwd -P)"
cleanup() {
	chmod -R u+w "${fixture}"
	rm -rf "${fixture}"
}
trap cleanup EXIT

export NIX_CONFIG='experimental-features = nix-command flakes'
export NIX_REMOTE="local?root=${fixture}/store"
export XDG_CACHE_HOME="${fixture}/cache"
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.hooksPath
export GIT_CONFIG_VALUE_1=/dev/null
export GIT_CONFIG_KEY_2=core.excludesFile
export GIT_CONFIG_VALUE_2=/dev/null
export GIT_AUTHOR_NAME='Updater test'
export GIT_AUTHOR_EMAIL='updater@example.invalid'
export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"

mkdir -p "${fixture}/source" "${fixture}/consumer/subdirectory"
git -C "${fixture}/source" init -q -b tracked
printf '%s\n' '{ outputs = _: {}; }' >"${fixture}/source/flake.nix"
git -C "${fixture}/source" add flake.nix
git -C "${fixture}/source" commit -qm initial

git -C "${fixture}/consumer" init -q
cat >"${fixture}/consumer/flake.nix" <<EOF
{
  inputs.hermes-agent.url = "git+file://${fixture}/source?ref=tracked";
  outputs = _: {};
}
EOF
git -C "${fixture}/consumer" add flake.nix
cp "${fixture}/consumer/flake.nix" "${fixture}/expected-flake.nix"

update() {
	(cd "${fixture}/consumer/subdirectory" && bash "${program}")
	cmp "${fixture}/expected-flake.nix" "${fixture}/consumer/flake.nix"
	local expected actual
	expected="$(git -C "${fixture}/source" rev-parse HEAD)"
	actual="$(jq -r '.nodes[.nodes.root.inputs["hermes-agent"]].locked.rev' "${fixture}/consumer/flake.lock")"
	if [[ "${actual}" != "${expected}" ]]; then
		echo "Expected branch revision ${expected}, got ${actual}" >&2
		exit 1
	fi
}

update
cp "${fixture}/consumer/flake.lock" "${fixture}/expected-lock.json"
update
cmp "${fixture}/expected-lock.json" "${fixture}/consumer/flake.lock"

printf '%s\n' advance >"${fixture}/source/change"
git -C "${fixture}/source" add change
git -C "${fixture}/source" commit -qm advance
update
previous="$(git -C "${fixture}/source" rev-parse HEAD)"

printf '%s\n' rewritten >"${fixture}/source/change"
git -C "${fixture}/source" commit -qam rewritten --amend
if git -C "${fixture}/source" merge-base --is-ancestor "${previous}" HEAD; then
	echo 'The fixture branch was not rewritten.' >&2
	exit 1
fi
update
