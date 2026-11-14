set -euo pipefail

updater="$1"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init --quiet
printf '%s\n' '{"semverGroups": [{"dependencies": ["@scope/tui"], "range": ""}, {"range": "^"}]}' >"$root/.syncpackrc.json"

# Starts the project from a package.json and the overrides in its
# pnpm-workspace.yaml. Each later argument is the lockfile that the next relock
# writes.
project() {
	rm -rf "$root/scenario" "$root/locks" "$root/calls" "$root/states"
	mkdir "$root/scenario" "$root/locks"
	printf '%s\n' "$1" >"$root/scenario/package.json"
	printf '%s\n' 'packages:' '  - "."' >"$root/scenario/pnpm-workspace.yaml"
	if [[ -n "$2" ]]; then
		printf '%s\n' 'overrides:' "$2" >>"$root/scenario/pnpm-workspace.yaml"
	fi
	printf '%s\n' "lockfileVersion: '9.0'" >"$root/scenario/pnpm-lock.yaml"
	shift 2

	local count=0 lock
	for lock in "$@"; do
		count=$((count + 1))
		printf '%s\n' "$lock" >"$root/locks/$count.yaml"
	done
}

update() {
	(cd "$root/scenario" && UPDATE_LOG="$root/calls" PNPM_LOCKS="$root/locks" PNPM_STATES="$root/states" "$updater")
}

# Prints the calls as `install`, `build <attribute>` and `nix-update`.
calls() {
	sed -E \
		-e 's/^pnpm:[^:]*:install .*/install/' \
		-e 's/^nix:[^:]*:build --no-link --print-out-paths \.#(.*)\.tarball$/build \1/' \
		-e 's/^nix-update:.*/nix-update/' \
		"$root/calls"
}

empty_lock="lockfileVersion: '9.0'"

# The updater rewrites the project's dependencies on local packages and their
# npm aliases, links the tarballs before relocking, and replaces the stale
# overrides with one for each local package and each alias. The project's own
# peer gets no global override.
project '{
  "name": "fixture",
  "dependencies": { "@scope/host": "^1", "alias": "npm:@scope/host@~1", "other": "^4" },
  "devDependencies": { "linked": "^0", "plain": "npm:linked" },
  "optionalDependencies": { "scoped": "npm:@scope/host" },
  "peerDependencies": { "@scope/host": "^1" }
}' '  other>dependency: "-"
  "@scope/host": file:.nix-providers/scope-host-1.0.0.tgz
  gone: file:.nix-providers/gone-1.0.0.tgz' "$empty_lock"
update

jq --sort-keys . "$root/scenario/package.json" >"$root/actual.json"
jq --sort-keys . >"$root/expected.json" <<'JSON'
{
  "name": "fixture",
  "dependencies": { "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz", "alias": "npm:@scope/host@^2.0.0", "other": "^4" },
  "devDependencies": { "linked": "^1.0.0", "plain": "npm:linked@^1.0.0" },
  "optionalDependencies": { "scoped": "npm:@scope/host@^2.0.0" },
  "peerDependencies": { "@scope/host": "^1" }
}
JSON
diff -u "$root/expected.json" "$root/actual.json"

yq -o=json '.' "$root/scenario/pnpm-workspace.yaml" >"$root/actual-workspace.json"
jq . >"$root/expected-workspace.json" <<'JSON'
{
  "packages": ["."],
  "overrides": {
    "other>dependency": "-",
    "alias": "file:.nix-providers/scope-host-2.0.0.tgz",
    "scoped": "file:.nix-providers/scope-host-2.0.0.tgz",
    "linked": "file:.nix-providers/linked-1.0.0.tgz",
    "plain": "file:.nix-providers/linked-1.0.0.tgz"
  }
}
JSON
diff -u "$root/expected-workspace.json" "$root/actual-workspace.json"

jq -s . "$root/states" >"$root/actual-states.json"
jq . >"$root/expected-states.json" <<'JSON'
[
  {
    "overrides": {
      "other>dependency": "-",
      "alias": "file:.nix-providers/scope-host-2.0.0.tgz",
      "scoped": "file:.nix-providers/scope-host-2.0.0.tgz",
      "linked": "file:.nix-providers/linked-1.0.0.tgz",
      "plain": "file:.nix-providers/linked-1.0.0.tgz"
    },
    "links": {
      "linked-1.0.0.tgz": "/nix/store/linked-tarball/package.tgz",
      "scope-host-2.0.0.tgz": "/nix/store/host-tarball/package.tgz"
    }
  }
]
JSON
diff -u "$root/expected-states.json" "$root/actual-states.json"

printf '%s\n' \
	"nix:$root:build --no-link --print-out-paths .#host.tarball" \
	"nix:$root:build --no-link --print-out-paths .#linked.tarball" \
	"pnpm:$root/scenario:install --lockfile-only --no-frozen-lockfile --ignore-scripts" \
	"nix-update:$root:--flake --override-filename scenario/package.nix --version=skip scenario" >"$root/expected-calls"
diff -u "$root/expected-calls" "$root/calls"

# A package that no longer uses local packages keeps no empty overrides map.
project '{"name": "plain", "dependencies": {"other": "^4"}}' '  gone: file:.nix-providers/gone-1.0.0.tgz' "$empty_lock"
update
yq -o=json '.' "$root/scenario/pnpm-workspace.yaml" | jq --sort-keys . | diff -u <(printf '%s\n' '{"packages": ["."]}' | jq --sort-keys .) -

# Prints every package.json in the project as one object keyed by path.
manifests() {
	(cd "$root/scenario" && find . -name package.json -not -path './.nix-providers/*' | sed 's|^\./||' | LC_ALL=C sort | xargs jq -n --sort-keys '[inputs | {(input_filename): .}] | add')
}

# Each case lists the project's package.json and overrides, the lockfiles that
# successive relocks write, the package.json that the update leaves, the
# overrides and links that each relock sees, and the calls. A case with
# workspace members also lists the workspace's patterns and the members'
# manifests before and after the update.
for case in private discovered direct-alias transitive-alias peer unchanged workspace followed; do
	packages='["."]'
	members='{}'
	updated_members='{}'
	case "$case" in
	private)
		# A private local package has no registry release, so it is linked
		# and overridden before the first relock.
		manifest='{"devDependencies": {"@dotfiles/private": "^0.1.0"}}'
		overrides=''
		locks=("lockfileVersion: '9.0'
packages:
  '@dotfiles/private@file:.nix-providers/dotfiles-private-0.1.0.tgz':
    resolution: {integrity: sha512-private, tarball: file:.nix-providers/dotfiles-private-0.1.0.tgz}")
		updated='{"devDependencies": {"@dotfiles/private": "^0.1.0"}}'
		states='[
			{"overrides": {"@dotfiles/private": "file:.nix-providers/dotfiles-private-0.1.0.tgz"},
			 "links": {"dotfiles-private-0.1.0.tgz": "/nix/store/private-tarball/package.tgz"}}
		]'
		expected_calls=("build private" install nix-update)
		;;
	discovered)
		# A registry package depends on a local package, which the first
		# relock resolves from the registry.
		manifest='{"dependencies": {"consumer": "^1"}}'
		overrides=''
		locks=("lockfileVersion: '9.0'
packages:
  consumer@1.0.0:
    resolution: {integrity: sha512-consumer}
  linked@1.0.0:
    resolution: {integrity: sha512-linked}
snapshots:
  consumer@1.0.0:
    dependencies:
      linked: 1.0.0" "lockfileVersion: '9.0'
packages:
  consumer@1.0.0:
    resolution: {integrity: sha512-consumer}
  linked@file:.nix-providers/linked-1.0.0.tgz:
    resolution: {integrity: sha512-tarball, tarball: file:.nix-providers/linked-1.0.0.tgz}
snapshots:
  consumer@1.0.0:
    dependencies:
      linked: file:.nix-providers/linked-1.0.0.tgz")
		updated="$manifest"
		states='[
			{"overrides": {}, "links": {}},
			{"overrides": {"linked": "file:.nix-providers/linked-1.0.0.tgz"},
			 "links": {"linked-1.0.0.tgz": "/nix/store/linked-tarball/package.tgz"}}
		]'
		expected_calls=(install "build linked" install nix-update)
		;;
	direct-alias)
		manifest='{"devDependencies": {"old": "npm:linked@^1"}}'
		overrides=''
		locks=("lockfileVersion: '9.0'
importers:
  .:
    devDependencies:
      old:
        specifier: npm:linked@1.0.0
        version: linked@file:.nix-providers/linked-1.0.0.tgz
packages:
  linked@file:.nix-providers/linked-1.0.0.tgz:
    resolution: {integrity: sha512-tarball, tarball: file:.nix-providers/linked-1.0.0.tgz}")
		updated='{"devDependencies": {"old": "npm:linked@^1.0.0"}}'
		states='[
			{"overrides": {"linked": "file:.nix-providers/linked-1.0.0.tgz", "old": "file:.nix-providers/linked-1.0.0.tgz"},
			 "links": {"linked-1.0.0.tgz": "/nix/store/linked-tarball/package.tgz"}}
		]'
		expected_calls=("build linked" install nix-update)
		;;
	transitive-alias)
		# A registry package depends on an npm alias of a local package.
		manifest='{"dependencies": {"consumer": "^1"}}'
		overrides=''
		locks=("lockfileVersion: '9.0'
packages:
  '@scope/host@2.0.0':
    resolution: {integrity: sha512-host}
  consumer@1.0.0:
    resolution: {integrity: sha512-consumer}
snapshots:
  consumer@1.0.0:
    dependencies:
      renamed: '@scope/host@2.0.0'" "lockfileVersion: '9.0'
packages:
  '@scope/host@file:.nix-providers/scope-host-2.0.0.tgz':
    resolution: {integrity: sha512-tarball, tarball: file:.nix-providers/scope-host-2.0.0.tgz}
  consumer@1.0.0:
    resolution: {integrity: sha512-consumer}
snapshots:
  consumer@1.0.0:
    dependencies:
      renamed: '@scope/host@file:.nix-providers/scope-host-2.0.0.tgz'")
		updated="$manifest"
		states='[
			{"overrides": {}, "links": {}},
			{"overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz", "renamed": "file:.nix-providers/scope-host-2.0.0.tgz"},
			 "links": {"scope-host-2.0.0.tgz": "/nix/store/host-tarball/package.tgz"}}
		]'
		expected_calls=(install "build host" install nix-update)
		;;
	peer)
		# pnpm turns a global override of the project's own peer into a
		# production dependency. The project's dependency points at the
		# tarball, and an override scoped to each dependent package replaces
		# the registry release.
		manifest='{"devDependencies": {"@scope/host": "^1"}, "peerDependencies": {"@scope/host": "^1"}}'
		overrides=''
		locks=()
		for host in 2.0.0 file:.nix-providers/scope-host-2.0.0.tgz; do
			locks+=("lockfileVersion: '9.0'
importers:
  .:
    devDependencies:
      '@scope/host':
        specifier: file:.nix-providers/scope-host-2.0.0.tgz
        version: file:.nix-providers/scope-host-2.0.0.tgz
snapshots:
  consumer@1.0.0(peer@1.0.0):
    dependencies:
      '@scope/host': $host")
		done
		updated='{"devDependencies": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"}, "peerDependencies": {"@scope/host": "^1"}}'
		states='[
			{"overrides": {}, "links": {"scope-host-2.0.0.tgz": "/nix/store/host-tarball/package.tgz"}},
			{"overrides": {"consumer>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"},
			 "links": {"scope-host-2.0.0.tgz": "/nix/store/host-tarball/package.tgz"}}
		]'
		expected_calls=("build host" install install nix-update)
		;;
	unchanged)
		# The repository's formatter writes double quotes, which the
		# update keeps.
		manifest='{"devDependencies": {"@scope/host": "^2.0.0", "linked": "^1.0.0"}}'
		overrides='  "@scope/host": file:.nix-providers/scope-host-2.0.0.tgz
  linked: file:.nix-providers/linked-1.0.0.tgz'
		locks=("lockfileVersion: '9.0'
packages:
  '@scope/host@file:.nix-providers/scope-host-2.0.0.tgz':
    resolution: {integrity: sha512-tarball, tarball: file:.nix-providers/scope-host-2.0.0.tgz}
  linked@file:.nix-providers/linked-1.0.0.tgz:
    resolution: {integrity: sha512-tarball, tarball: file:.nix-providers/linked-1.0.0.tgz}")
		updated="$manifest"
		states='[
			{"overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz", "linked": "file:.nix-providers/linked-1.0.0.tgz"},
			 "links": {"linked-1.0.0.tgz": "/nix/store/linked-tarball/package.tgz", "scope-host-2.0.0.tgz": "/nix/store/host-tarball/package.tgz"}}
		]'
		expected_calls=("build host" "build linked" install nix-update)
		;;
	workspace)
		# pnpm-workspace.yaml lists the members. A negated pattern excludes
		# a member.
		manifest='{"name": "workspace"}'
		packages='["packages/*", "!packages/ignored"]'
		members='{
			"packages/app/package.json": {"dependencies": {"linked": "^0"}},
			"packages/tool/package.json": {"devDependencies": {"renamed": "npm:@scope/host"}},
			"packages/ignored/package.json": {"dependencies": {"@dotfiles/private": "^0.1.0"}}
		}'
		overrides=''
		locks=("$empty_lock")
		updated="$manifest"
		updated_members='{
			"packages/app/package.json": {"dependencies": {"linked": "^1.0.0"}},
			"packages/tool/package.json": {"devDependencies": {"renamed": "npm:@scope/host@^2.0.0"}},
			"packages/ignored/package.json": {"dependencies": {"@dotfiles/private": "^0.1.0"}}
		}'
		states='[
			{"overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz", "renamed": "file:.nix-providers/scope-host-2.0.0.tgz", "linked": "file:.nix-providers/linked-1.0.0.tgz"},
			 "links": {"linked-1.0.0.tgz": "/nix/store/linked-tarball/package.tgz", "scope-host-2.0.0.tgz": "/nix/store/host-tarball/package.tgz"}}
		]'
		expected_calls=("build host" "build linked" install nix-update)
		;;
	followed)
		# A local package from this repository depends on a private local
		# package, which has no registry release for the relock to find.
		manifest='{"dependencies": {"@dotfiles/consumer": "^1.0.0"}}'
		overrides=''
		locks=("$empty_lock")
		updated="$manifest"
		states='[
			{"overrides": {"@dotfiles/consumer": "file:.nix-providers/dotfiles-consumer-1.0.0.tgz", "@dotfiles/private": "file:.nix-providers/dotfiles-private-0.1.0.tgz"},
			 "links": {"dotfiles-consumer-1.0.0.tgz": "/nix/store/consumer-tarball/package.tgz", "dotfiles-private-0.1.0.tgz": "/nix/store/private-tarball/package.tgz"}}
		]'
		expected_calls=("build consumer" "build private" install nix-update)
		;;
	esac

	project "$manifest" "$overrides" "${locks[@]}"
	packages="$packages" yq -i '.packages = env(packages)' "$root/scenario/pnpm-workspace.yaml"
	while IFS=$'\t' read -r path member; do
		mkdir -p "$root/scenario/${path%/*}"
		printf '%s\n' "$member" >"$root/scenario/$path"
	done < <(jq -r 'to_entries[] | [.key, (.value | tojson)] | @tsv' <<<"$members")
	cp "$root/scenario/pnpm-workspace.yaml" "$root/workspace-before.yaml"
	update

	jq -n --sort-keys --argjson root "$updated" --argjson members "$updated_members" '{"package.json": $root} + $members' | diff -u - <(manifests)
	jq --sort-keys . <<<"$states" | diff -u - <(jq -s --sort-keys . "$root/states")
	printf '%s\n' "${expected_calls[@]}" | diff -u - <(calls)
	if [[ "$case" == unchanged ]]; then
		diff -u "$root/workspace-before.yaml" "$root/scenario/pnpm-workspace.yaml"
	fi
done

# A lockfile that adds another npm alias of a local package after every relock
# stops the update.
locks=()
for count in $(seq 10); do
	locks+=("lockfileVersion: '9.0'
snapshots:
  consumer@1.0.0:
    dependencies:
      alias-$count: linked@1.0.0")
done
project '{"dependencies": {"consumer": "^1"}}' '' "${locks[@]}"
if update 2>"$root/unstable.log"; then
	echo 'A lockfile that never stops changing must stop the update.' >&2
	exit 1
fi
printf '%s\n' 'Relocking still added local npm packages after 10 rounds.' | diff -u - "$root/unstable.log"

# A direct dependency moves to the exact version that a local package installs,
# so pnpm installs one copy, with one set of module state.
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

tui='{"name": "scenario", "devDependencies": {"@scope/tui": "^1.0.0", "other": "^4"}}'
project "$tui" '' "$(lock 1.0.0 host 1.1.0)" "$(lock 1.1.0 host 1.1.0)"
update
jq -c .devDependencies "$root/scenario/package.json" | diff -u <(printf '%s\n' '{"@scope/tui":"1.1.0","other":"^4"}') -
printf '%s\n' install install nix-update | diff -u - <(calls)

# The guard also moves a workspace member's direct dependency.
member_lock() {
	cat <<EOF
lockfileVersion: '9.0'

importers:

  .: {}

  packages/app:
    dependencies:
      '@scope/tui':
        specifier: $1
        version: $1

snapshots:

  'host@file:.nix-providers/host.tgz':
    dependencies:
      '@scope/tui': 1.1.0
EOF
}
project '{"name": "workspace"}' '' "$(member_lock 1.0.0)" "$(member_lock 1.1.0)"
yq -i '.packages = ["packages/*"]' "$root/scenario/pnpm-workspace.yaml"
mkdir -p "$root/scenario/packages/app"
printf '%s\n' '{"dependencies": {"@scope/tui": "^1.0.0"}}' >"$root/scenario/packages/app/package.json"
update
jq -n --sort-keys '{"package.json": {"name": "workspace"}, "packages/app/package.json": {"dependencies": {"@scope/tui": "1.1.0"}}}' | diff -u - <(manifests)

# Local packages that need different versions of a direct dependency, an exact
# version that syncpack would reject, and a relock that still installs two
# copies stop the update.
for case in conflict syncpack persistent; do
	cp "$root/.syncpackrc.json" "$root/syncpackrc.json"
	case "$case" in
	conflict)
		project "$tui" '' "$(lock 1.0.0 host 1.1.0 linked 1.2.0)"
		expected='Local packages need different versions of @scope/tui: 1.1.0 1.2.0'
		;;
	syncpack)
		printf '%s\n' '{"semverGroups": [{"range": "^"}]}' >"$root/.syncpackrc.json"
		project "$tui" '' "$(lock 1.0.0 host 1.1.0)"
		expected='@scope/tui needs the exact version 1.1.0, which a local package installs, but .syncpackrc.json allows exact versions only for the dependencies in its semver group with "range": "". Add @scope/tui to that group.'
		;;
	persistent)
		project "$tui" '' "$(lock 1.0.0 host 1.1.0)" "$(lock 1.0.0 host 1.1.0)"
		expected='pnpm still installs a second copy of @scope/tui beside a local package.'
		;;
	esac
	if update 2>"$root/$case.log"; then
		printf 'The %s case must stop the update.\n' "$case" >&2
		exit 1
	fi
	printf '%s\n' "$expected" | diff -u - "$root/$case.log"
	mv "$root/syncpackrc.json" "$root/.syncpackrc.json"
done
