# shellcheck shell=bash

set -euo pipefail

program="$1"
fixture="$(mktemp -d)"
fixture="$(cd "${fixture}" && pwd -P)"
trap 'rm -rf "${fixture}"' EXIT

# The stub records each npm invocation and, in place of resolving against the
# registry, copies the lockfile prepared for that invocation: `locks/0.json`
# for the first, `locks/1.json` for the second.
mkdir -p "${fixture}/bin"
{
	printf '#!%s\n' "${BASH}"
	cat <<'STUB'
call="$(wc -l <"${NPM_CALLS}")"
printf '%s\n' "$*" >>"${NPM_CALLS}"
cp "${NPM_LOCKS}/$((call)).json" package-lock.json
STUB
} >"${fixture}/bin/npm"
chmod +x "${fixture}/bin/npm"
export PATH="${fixture}/bin:${PATH}"
export NPM_CALLS="${fixture}/calls"
export NPM_LOCKS="${fixture}/locks"

cat >"${fixture}/provided.json" <<'JSON'
[
  {"name": "@scope/host", "version": "2.0.0"},
  {"name": "tool", "version": "3.0.0"}
]
JSON

# A lockfile in which `@scope/host` is at version $1 and depends on `shared`
# ^2.0.0. $2 is the version of the top-level `shared`. $3, if set, is the
# version of a `shared` copy nested under `@scope/host` and its alias. `tool`
# depends on `shared` too, and $4, if set, is the version of a `shared` copy
# nested under `tool`.
lock() {
	local host="$1" shared="$2" nested="${3:-}" tool_shared="${4:-}"

	jq -n --arg host "${host}" --arg shared "${shared}" --arg nested "${nested}" --arg tool_shared "${tool_shared}" '
		{
			lockfileVersion: 3,
			packages: (
				{
					"": {},
					"node_modules/@scope/host": {version: $host, dependencies: {shared: "^2.0.0"}},
					"node_modules/alias": {name: "@scope/host", version: $host, dependencies: {shared: "^2.0.0"}},
					"node_modules/tool": {version: "3.0.0", dependencies: {shared: "*"}},
					"node_modules/shared": {version: $shared}
				}
				+ if $nested == "" then {} else {
					"node_modules/@scope/host/node_modules/shared": {version: $nested},
					"node_modules/alias/node_modules/shared": {version: $nested}
				} end
				+ if $tool_shared == "" then {} else {
					"node_modules/tool/node_modules/shared": {version: $tool_shared}
				} end
			)
		}'
}

consumer() {
	rm -rf "${fixture}/consumer" "${NPM_LOCKS}"
	mkdir -p "${fixture}/consumer" "${NPM_LOCKS}"
	printf '%s\n' "$1" >"${fixture}/consumer/package.json"
	: >"${NPM_CALLS}"
}

update() {
	(cd "${fixture}/consumer" && bash "${program}" "${fixture}/provided.json") 2>"${fixture}/stderr"
}

expect() {
	local name="$1" status="$2" calls="$3" stderr="$4" actual=0

	update || actual=$?
	if ! diff -u <(printf 'status %s\n%s---\n%s' "${status}" "${calls}" "${stderr}${stderr:+$'\n'}") \
		<(printf 'status %s\n%s---\n%s' "${actual}" "$(cat "${NPM_CALLS}")${calls:+$'\n'}" "$(cat "${fixture}/stderr")${stderr:+$'\n'}"); then
		echo "Unexpected result: ${name}" >&2
		exit 1
	fi
}

# A stale pin on a local package, or on an alias of it, moves to the local
# version. npm then resolves the local package's `shared` dependency to 2.1.0
# under it, beside the top-level 1.0.0, so the direct dependency on `shared`
# moves to 2.1.0 and npm installs one copy.
consumer '{"dependencies": {"tool": "3.0.0", "shared": "1.0.0"}, "devDependencies": {"@scope/host": "1.0.0", "alias": "npm:@scope/host@1.0.0"}}'
lock 1.0.0 1.0.0 >"${fixture}/consumer/package-lock.json"
lock 2.0.0 1.0.0 2.1.0 >"${NPM_LOCKS}/0.json"
lock 2.0.0 2.1.0 >"${NPM_LOCKS}/1.json"
expect "stale pins" 0 'install --package-lock-only --ignore-scripts --save-exact --save-dev @scope/host@2.0.0 alias@npm:@scope/host@2.0.0
install --package-lock-only --ignore-scripts --save-exact --save-prod shared@2.1.0
' ''

# A peer dependency on a local package moves to the local version, and npm
# resolves the lockfile again.
consumer '{"devDependencies": {"@scope/host": "2.0.0"}, "peerDependencies": {"@scope/host": "1.0.0"}}'
lock 2.0.0 2.1.0 >"${fixture}/consumer/package-lock.json"
lock 2.0.0 2.1.0 >"${NPM_LOCKS}/0.json"
expect "peer pin" 0 'install --package-lock-only --ignore-scripts
' ''
if ! diff -u <(printf '%s\n' '{"@scope/host":"2.0.0"}') <(jq -c .peerDependencies "${fixture}/consumer/package.json"); then
	echo "Expected the peer dependency to move to the local version" >&2
	exit 1
fi

# A package.json and lockfile that already use the local versions need no npm
# invocation.
consumer '{"dependencies": {"tool": "3.0.0", "shared": "2.1.0"}, "devDependencies": {"@scope/host": "2.0.0", "alias": "npm:@scope/host@2.0.0"}}'
lock 2.0.0 2.1.0 >"${fixture}/consumer/package-lock.json"
expect "current" 0 '' ''

# Two local packages that nest different versions of `shared` cannot share one
# copy.
consumer '{"dependencies": {"tool": "3.0.0", "shared": "1.0.0"}, "devDependencies": {"@scope/host": "2.0.0"}}'
lock 2.0.0 1.0.0 2.1.0 2.2.0 >"${fixture}/consumer/package-lock.json"
expect "conflict" 1 '' 'Local npm packages resolve these dependencies to different versions:
  shared: 2.1.0 (node_modules/@scope/host), 2.1.0 (node_modules/alias), 2.2.0 (node_modules/tool)'

# When moving `shared` makes npm nest the old version under another local
# package, which needs it, the updater reports the remaining second copy.
consumer '{"dependencies": {"tool": "3.0.0", "shared": "1.0.0"}, "devDependencies": {"@scope/host": "2.0.0"}}'
lock 2.0.0 1.0.0 2.1.0 >"${fixture}/consumer/package-lock.json"
lock 2.0.0 2.1.0 "" 1.0.0 >"${NPM_LOCKS}/0.json"
expect "second copy after the move" 1 'install --package-lock-only --ignore-scripts --save-exact --save-prod shared@2.1.0
' 'npm still installs a second copy of these dependencies under local npm packages:
  shared: 1.0.0 under node_modules/tool'

# A lockfile that is stale although package.json already pins the local
# versions is resolved again.
consumer '{"dependencies": {"shared": "2.1.0"}, "devDependencies": {"@scope/host": "2.0.0"}}'
lock 1.0.0 2.1.0 >"${fixture}/consumer/package-lock.json"
lock 2.0.0 2.1.0 >"${NPM_LOCKS}/0.json"
expect "stale lockfile with current pins" 0 'install --package-lock-only --ignore-scripts
' ''

# A lockfile that still resolves a local package to another version after
# resolving again is an error, and the updater lists each entry.
consumer '{"dependencies": {"shared": "2.1.0"}, "devDependencies": {"@scope/host": "1.0.0"}}'
lock 1.0.0 2.1.0 >"${fixture}/consumer/package-lock.json"
lock 1.0.0 2.1.0 >"${NPM_LOCKS}/0.json"
lock 1.0.0 2.1.0 >"${NPM_LOCKS}/1.json"
expect "stale lockfile" 1 'install --package-lock-only --ignore-scripts --save-exact --save-dev @scope/host@2.0.0
install --package-lock-only --ignore-scripts
' "The lockfile resolves these entries to versions that differ from the local npm packages' versions:
  node_modules/@scope/host: 1.0.0 (local 2.0.0)
  node_modules/alias: 1.0.0 (local 2.0.0)"
