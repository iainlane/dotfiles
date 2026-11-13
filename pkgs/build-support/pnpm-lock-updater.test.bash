set -euo pipefail

updater="$1"
updater_without_providers="$2"
updater_with_lockfiles="$3"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir "$root/fixture"
git -C "$root" init --quiet
cat >"$root/fixture/package.json" <<'JSON'
{
  "name": "fixture",
  "dependencies": { "@scope/host": "^1", "alias": "npm:@scope/host@~1", "other": "^4" },
  "devDependencies": { "linked": "^0", "plain": "npm:linked" },
  "optionalDependencies": { "scoped": "npm:@scope/host" },
  "peerDependencies": { "@scope/host": "^1" }
}
JSON
cat >"$root/fixture/pnpm-workspace.yaml" <<'YAML'
packages:
  - "."

overrides:
  other>dependency: "-"
  "@scope/host": file:.nix-providers/scope-host-1.0.0.tgz
  gone: file:.nix-providers/gone-1.0.0.tgz
YAML
printf '%s\n' "lockfileVersion: '9.0'" >"$root/fixture/pnpm-lock.yaml"
export UPDATE_LOG="$root/calls"
export NIX_EVAL='[{"file":"scope-host-2.0.0.tgz","name":"@scope/host","version":"2.0.0"},{"file":"linked-1.0.0.tgz","name":"linked","version":"1.0.0"}]'
cd "$root/fixture"
"$updater"

jq --sort-keys . package.json >"$root/actual.json"
jq --sort-keys . >"$root/expected.json" <<'JSON'
{
  "name": "fixture",
  "dependencies": { "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz", "alias": "npm:@scope/host@2.0.0", "other": "^4" },
  "devDependencies": { "linked": "1.0.0", "plain": "npm:linked@1.0.0" },
  "optionalDependencies": { "scoped": "npm:@scope/host@2.0.0" },
  "peerDependencies": { "@scope/host": "^1" }
}
JSON
diff -u "$root/expected.json" "$root/actual.json"

yq -o=json '.' pnpm-workspace.yaml | jq --sort-keys . >"$root/actual-workspace.json"
jq --sort-keys . >"$root/expected-workspace.json" <<'JSON'
{
  "packages": ["."],
  "overrides": {
    "other>dependency": "-",
    "linked": "file:.nix-providers/linked-1.0.0.tgz"
  }
}
JSON
diff -u "$root/expected-workspace.json" "$root/actual-workspace.json"

printf '%s\n' \
	"./linked-1.0.0.tgz -> /nix/store/linked.tgz" \
	"./scope-host-2.0.0.tgz -> /nix/store/@scope/host.tgz" >"$root/expected-links"
(cd .nix-providers && for link in ./*; do printf '%s -> %s\n' "$link" "$(readlink "$link")"; done) | diff -u "$root/expected-links" -
printf '%s\n' \
	"pnpm:$root/fixture:install --lockfile-only --no-frozen-lockfile --ignore-scripts" \
	"nix:$root:eval --json .#fixture.passthru.updateScript.providers" \
	"nix-update:$root:--flake --system aarch64-darwin --override-filename fixture/package.nix --version=skip fixture" \
	"nix-update:$root:--flake --system aarch64-linux --override-filename fixture/package.nix --version=skip fixture" \
	"nix-update:$root:--flake --system x86_64-linux --override-filename fixture/package.nix --version=skip fixture" >"$root/expected-calls"
diff -u "$root/expected-calls" "$UPDATE_LOG"

plain() {
	rm -rf "$root/plain"
	mkdir "$root/plain"
	printf '%s\n' '{"name": "plain", "dependencies": {"other": "^4"}}' >"$root/plain/package.json"
	cat >"$root/plain/pnpm-workspace.yaml" <<'YAML'
packages:
  - "."

overrides:
  gone: file:.nix-providers/gone-1.0.0.tgz
YAML
	printf '%s\n' "lockfileVersion: '9.0'" >"$root/plain/pnpm-lock.yaml"
}

# A package that no longer uses local packages keeps no empty overrides map.
plain
cd "$root/plain"
NIX_EVAL='[]' UPDATE_LOG="$root/plain-calls" "$updater_without_providers"
yq -o=json '.' pnpm-workspace.yaml | jq --sort-keys . | diff -u <(printf '%s\n' '{"packages": ["."]}' | jq --sort-keys .) -
cd "$root"

# A relock that adds a local package runs the updater again, as built from the
# new lockfile, so that the new package's tarball is linked. A second change
# stops the update.
mkdir -p "$root/rerun/bin"
printf '#!%s\n' "$(command -v bash)" >"$root/rerun/bin/update-plain"
cat >>"$root/rerun/bin/update-plain" <<'BASH'
printf 'rerun:%s:%s\n' "$PNPM_LOCK_UPDATER_RERUN" "$*" >>"$UPDATE_LOG"
BASH
chmod +x "$root/rerun/bin/update-plain"
added='[{"file":"added-1.0.0.tgz","name":"added","version":"1.0.0"}]'

plain
(cd "$root/plain" && NIX_EVAL="$added" NIX_BUILD="$root/rerun" UPDATE_LOG="$root/rerun-calls" "$updater_without_providers" argument)
printf '%s\n' \
	"pnpm:$root/plain:install --lockfile-only --no-frozen-lockfile --ignore-scripts" \
	"nix:$root:eval --json .#plain.passthru.updateScript.providers" \
	"nix:$root:build --no-link --print-out-paths .#plain.passthru.updateScript" \
	"rerun:1:argument" | diff -u - "$root/rerun-calls"

plain
if (cd "$root/plain" && PNPM_LOCK_UPDATER_RERUN=1 NIX_EVAL="$added" UPDATE_LOG="$root/again-calls" "$updater_without_providers") 2>"$root/again.log"; then
	echo 'A second change to the local packages must stop the update.' >&2
	exit 1
fi
printf '%s\n' 'Relocking plain changed its local npm packages again.' | diff -u - "$root/again.log"

# A direct dependency moves to the version that a local package installs, so
# pnpm installs one copy, with one set of module state.
lock() {
	local direct="$1"
	shift

	cat <<EOF
lockfileVersion: '9.0'

importers:

  .:
    devDependencies:
      '@scope/tui':
        specifier: $direct
        version: $direct(peer@1.0.0)
      other:
        specifier: ^4
        version: 4.1.0

snapshots:
EOF
	while (($# > 0)); do
		cat <<EOF

  '$1@file:.nix-providers/$1.tgz(peer@1.0.0)':
    dependencies:
      '@scope/tui': $2(peer@1.0.0)
      alias: other@4.1.0
      other: 4.1.0
EOF
		shift 2
	done
}

lock 1.0.0 host 1.1.0 >"$root/locks-moved-1.yaml"
lock 1.1.0 host 1.1.0 >"$root/locks-moved-2.yaml"
rm -f "$root/scenario-calls"
(
	set -e
	rm -rf "$root/scenario" "$root/locks"
	mkdir "$root/scenario" "$root/locks"
	cp "$root/locks-moved-1.yaml" "$root/locks/1.yaml"
	cp "$root/locks-moved-2.yaml" "$root/locks/2.yaml"
	printf '%s\n' '{"name": "scenario", "devDependencies": {"@scope/tui": "1.0.0", "other": "^4"}}' >"$root/scenario/package.json"
	printf '%s\n' 'packages:' '  - "."' >"$root/scenario/pnpm-workspace.yaml"
	cd "$root/scenario"
	PNPM_LOCKS="$root/locks" UPDATE_LOG="$root/scenario-calls" "$updater_with_lockfiles"
)
jq -c .devDependencies "$root/scenario/package.json" | diff -u <(printf '%s\n' '{"@scope/tui":"1.1.0","other":"^4"}') -
diff -u <(printf '%s\n' install install) <(sed -nE 's/^pnpm:[^:]*:(install).*/\1/p' "$root/scenario-calls")

# Local packages that need different versions of a direct dependency, and a
# relock that still installs two copies, stop the update.
for case in conflict persistent; do
	rm -rf "$root/scenario" "$root/locks"
	mkdir "$root/scenario" "$root/locks"
	case "$case" in
	conflict)
		lock 1.0.0 host 1.1.0 linked 1.2.0 >"$root/locks/1.yaml"
		expected='Local packages need different versions of @scope/tui: 1.1.0 1.2.0'
		;;
	persistent)
		lock 1.0.0 host 1.1.0 >"$root/locks/1.yaml"
		lock 1.0.0 host 1.1.0 >"$root/locks/2.yaml"
		expected='pnpm still installs a second copy of @scope/tui beside a local package.'
		;;
	esac
	printf '%s\n' '{"name": "scenario", "devDependencies": {"@scope/tui": "1.0.0", "other": "^4"}}' >"$root/scenario/package.json"
	printf '%s\n' 'packages:' '  - "."' >"$root/scenario/pnpm-workspace.yaml"
	if (cd "$root/scenario" && PNPM_LOCKS="$root/locks" UPDATE_LOG="$root/$case-calls" "$updater_with_lockfiles") 2>"$root/$case.log"; then
		printf 'The %s case must stop the update.\n' "$case" >&2
		exit 1
	fi
	printf '%s\n' "$expected" | diff -u - "$root/$case.log"
done

# A local package that the project declares as its own peer gets no global
# override, which pnpm would turn into a production dependency. The project's
# dependency points at the tarball, and an override scoped to each dependent
# package replaces the registry release.
rm -rf "$root/scenario" "$root/locks"
mkdir "$root/scenario" "$root/locks"
peer_lock() {
	cat <<LOCK
lockfileVersion: '9.0'

importers:

  .:
    devDependencies:
      '@scope/host':
        specifier: file:.nix-providers/scope-host-2.0.0.tgz
        version: file:.nix-providers/scope-host-2.0.0.tgz

snapshots:

  consumer@1.0.0(peer@1.0.0):
    dependencies:
      '@scope/host': $1
LOCK
}
peer_lock 2.0.0 >"$root/locks/1.yaml"
peer_lock file:.nix-providers/scope-host-2.0.0.tgz >"$root/locks/2.yaml"
printf '%s\n' '{"name": "scenario", "devDependencies": {"@scope/host": "^1"}, "peerDependencies": {"@scope/host": "^1"}}' >"$root/scenario/package.json"
printf '%s\n' 'packages:' '  - "."' >"$root/scenario/pnpm-workspace.yaml"
(cd "$root/scenario" && PNPM_LOCKS="$root/locks" UPDATE_LOG="$root/peer-calls" "$updater_with_lockfiles")
jq -c '{devDependencies, peerDependencies}' "$root/scenario/package.json" |
	diff -u <(printf '%s\n' '{"devDependencies":{"@scope/host":"file:.nix-providers/scope-host-2.0.0.tgz"},"peerDependencies":{"@scope/host":"^1"}}') -
yq -o=json '.overrides' "$root/scenario/pnpm-workspace.yaml" | jq --sort-keys . |
	diff -u <(printf '%s\n' '{"consumer>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz", "linked": "file:.nix-providers/linked-1.0.0.tgz"}' | jq --sort-keys .) -
diff -u <(printf '%s\n' install install) <(sed -nE 's/^pnpm:[^:]*:(install).*/\1/p' "$root/peer-calls")
