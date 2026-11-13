set -euo pipefail

script="$1"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

touch "$root/core.tgz" "$root/shared.tgz" "$root/old.tgz"

# Linking replaces earlier links and leaves other files alone.
mkdir -p "$root/package/.nix-providers"
ln -s "$root/old.tgz" "$root/package/.nix-providers/scope-old-0.1.0.tgz"
touch "$root/package/.nix-providers/notes.txt"
bash "$script" link "$root/package" \
	scope-core-1.0.0.tgz "$root/core.tgz" \
	shared-2.0.0.tgz "$root/shared.tgz"
diff -u - <(cd "$root/package/.nix-providers" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r path; do
	if [[ -L "$path" ]]; then
		printf '%s -> %s\n' "$path" "$(readlink "$path")"
	else
		printf '%s\n' "$path"
	fi
done) <<EOF
./notes.txt
./scope-core-1.0.0.tgz -> $root/core.tgz
./shared-2.0.0.tgz -> $root/shared.tgz
EOF

# Writes a lockfile with the given overrides; the first argument lists the
# lockfile's package keys.
lockfile() {
	local packages="$1"

	cat <<EOF
lockfileVersion: '9.0'

settings:
  autoInstallPeers: false

overrides:
$(cat)

importers:

packages:
$packages
EOF
}

check() {
	bash "$script" check "$1" \
		@scope/core scope-core-1.0.0.tgz \
		shared shared-2.0.0.tgz
}

installed=$'  \'@scope/core@file:.nix-providers/scope-core-1.0.0.tgz\': {}\n  shared@file:.nix-providers/shared-2.0.0.tgz: {}\n  other@1.0.0: {}'

# The overrides match the providers, whatever their quoting.
lockfile "$installed" >"$root/current.yaml" <<'EOF'
  '@scope/core': file:.nix-providers/scope-core-1.0.0.tgz
  other>dependency: '-'
  shared: file:.nix-providers/shared-2.0.0.tgz
EOF
check "$root/current.yaml"

# An override scoped to a parent package counts for its target.
lockfile "$installed" >"$root/scoped.yaml" <<'EOF'
  consumer>@scope/core: file:.nix-providers/scope-core-1.0.0.tgz
  shared: file:.nix-providers/shared-2.0.0.tgz
EOF
check "$root/scoped.yaml"

# A registry release of a local package, an outdated override and an override
# for a package that no longer exists fail with the same advice.
for case in registry outdated extra; do
	packages="$installed"
	case "$case" in
	registry)
		overrides="  shared: file:.nix-providers/shared-2.0.0.tgz"
		packages+=$'\n  \'@scope/core@1.0.0\': {}'
		;;
	outdated)
		overrides=$'  \'@scope/core\': file:.nix-providers/scope-core-0.9.0.tgz\n  shared: file:.nix-providers/shared-2.0.0.tgz'
		;;
	extra)
		overrides=$'  \'@scope/core\': file:.nix-providers/scope-core-1.0.0.tgz\n  gone: file:.nix-providers/gone-1.0.0.tgz\n  shared: file:.nix-providers/shared-2.0.0.tgz'
		;;
	esac

	lockfile "$packages" >"$root/$case.yaml" <<<"$overrides"
	if check "$root/$case.yaml" 2>"$root/$case.log"; then
		printf 'A lockfile with a %s provider must fail the check.\n' "$case" >&2
		exit 1
	fi
	printf '%s\n' 'The lockfile does not install the local npm packages. Run the package'"'"'s updater.' | diff -u - "$root/$case.log"
done
