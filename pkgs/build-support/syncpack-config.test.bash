set -euo pipefail

config="$1"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export HOME="$root/home"
mkdir "$HOME"

# The pnpm lock updater writes an exact version only for a dependency in the
# semver group with "range": "".
exact="$(jq -r '[.semverGroups[] | select(.range == "") | .dependencies[]][0]' "$config")"

# Each case is a workspace that declares one dependency, and the exit status
# that `syncpack lint` must return for it. The dependency is in the exact group
# or, as `other`, in the group that requires caret ranges.
cases="$(jq -n --arg exact "$exact" '[
  {
    name: "an exact version in the default catalog",
    manifest: {devDependencies: {($exact): "catalog:"}},
    workspace: {catalog: {($exact): "1.1.0"}},
    status: 0
  },
  {
    name: "an exact version in a named catalog",
    manifest: {devDependencies: {($exact): "catalog:tools"}},
    workspace: {catalogs: {tools: {($exact): "1.1.0"}}},
    status: 0
  },
  {
    name: "an exact version without catalogs, and a peer range",
    manifest: {devDependencies: {($exact): "1.1.0"}, peerDependencies: {($exact): "^1.0.0"}},
    workspace: {},
    status: 0
  },
  {
    name: "a catalog entry outside the exact group with an exact version",
    manifest: {devDependencies: {other: "catalog:"}},
    workspace: {catalog: {other: "1.1.0"}},
    status: 1
  },
  {
    name: "a catalog entry outside the exact group with a caret range",
    manifest: {devDependencies: {other: "catalog:"}},
    workspace: {catalog: {other: "^1.1.0"}},
    status: 0
  }
]')"

failed=0
while IFS= read -r case; do
	workspace="$root/workspace"
	rm -rf "$workspace"
	mkdir "$workspace"
	jq '{name: "fixture", version: "1.0.0"} + .manifest' <<<"$case" >"$workspace/package.json"
	jq '{packages: ["."]} + .workspace' <<<"$case" | yq -P -o=yaml . >"$workspace/pnpm-workspace.yaml"

	status=0
	(cd "$workspace" && syncpack lint --config "$config" >"$root/lint.log" 2>&1) || status=$?
	expected="$(jq -r .status <<<"$case")"
	if ((status != expected)); then
		printf '%s: syncpack lint exited with %s, expected %s.\n' "$(jq -r .name <<<"$case")" "$status" "$expected" >&2
		cat "$root/lint.log" >&2
		failed=1
	fi
done < <(jq -c '.[]' <<<"$cases")

exit "$failed"
