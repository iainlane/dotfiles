# shellcheck shell=bash

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
cat >"$root/fixture/pnpm-workspace.yaml" <<'YAML'
packages:
  - "."
packageExtensions:
  "@scope/host@1.0.0":
    dependencies:
      stale: "^1"
  other@4.0.0:
    dependencies:
      kept: "^1"
YAML
mkdir "$root/registry"
echo '{"name": "@scope/host", "version": "2.0.0", "peerDependencies": {"peer": "*"}}' >"$root/registry/@scope+host@2.0.0.json"
echo '{"name": "linked", "version": "1.0.0"}' >"$root/registry/linked@1.0.0.json"
export REGISTRY="$root/registry"
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
yq -o json pnpm-workspace.yaml | jq --sort-keys . >"$root/actual-workspace.json"
jq --sort-keys . >"$root/expected-workspace.json" <<'JSON'
{
  "packages": ["."],
  "packageExtensions": {
    "@scope/host@2.0.0": { "dependencies": { "shared": "^1" } },
    "other@4.0.0": { "dependencies": { "kept": "^1" } }
  }
}
JSON
diff -u "$root/expected-workspace.json" "$root/actual-workspace.json"
printf '%s\n' \
	"npm:$root/fixture:view @scope/host@2.0.0 --json" \
	"npm:$root/fixture:view linked@1.0.0 --json" \
	"pnpm:$root/fixture:install --lockfile-only --no-frozen-lockfile --ignore-scripts" \
	"nix-update:$root:--flake --version=skip --no-src --override-filename fixture/package.nix fixture" >"$root/expected-calls"
diff -u "$root/expected-calls" "$UPDATE_LOG"
