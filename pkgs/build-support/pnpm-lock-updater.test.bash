set -euo pipefail

updater="$1"
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
export UPDATE_LOG="$root/calls"
cd "$root/fixture"
"$updater"

jq --sort-keys . package.json >"$root/actual.json"
jq --sort-keys . >"$root/expected.json" <<'JSON'
{
  "name": "fixture",
  "dependencies": { "@scope/host": "2.0.0", "alias": "npm:@scope/host@2.0.0", "other": "^4" },
  "devDependencies": { "linked": "1.0.0", "plain": "npm:linked@1.0.0" },
  "optionalDependencies": { "scoped": "npm:@scope/host@2.0.0" },
  "peerDependencies": { "@scope/host": "^1" }
}
JSON
diff -u "$root/expected.json" "$root/actual.json"
printf '%s\n' \
	"pnpm:$root/fixture:install --lockfile-only --no-frozen-lockfile --ignore-scripts" \
	"nix-update:$root:--flake --system aarch64-darwin --override-filename fixture/package.nix --version=skip fixture" \
	"nix-update:$root:--flake --system aarch64-linux --override-filename fixture/package.nix --version=skip fixture" \
	"nix-update:$root:--flake --system x86_64-linux --override-filename fixture/package.nix --version=skip fixture" >"$root/expected-calls"
diff -u "$root/expected-calls" "$UPDATE_LOG"
